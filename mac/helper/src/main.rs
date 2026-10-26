// gs-helper: everything the Mac window used Xcode for, without Xcode.
//
//   gs-helper devices                         plugged-in iPhones: name, trusted, Developer Mode
//   gs-helper apps     --udid U               installed user apps
//   gs-helper trust    --udid U               show the Trust prompt on the phone
//   gs-helper devmode  --udid U               make Settings show the Developer Mode switch
//   gs-helper status   --udid U --bundle B    the app's Documents/status.json
//   gs-helper login    --data D               sign in with an Apple ID, list its teams
//   gs-helper install  --data D --udid U --ipa I --team T --pairing P
//                                             sign I with the Apple ID, install, pair
//
// Output is JSON lines on stdout: progress events ({"stage":…} / {"progress":…}), a 2FA request
// ({"need":"code",…}), and one final {"ok":true,…} or {"ok":false,"error":…,"details":…}.
// login/install read {"email","password"} as the first stdin line; 2FA answers come as later lines:
// {"code":"123456"} or {"abort":true}.

use std::{collections::HashMap, io::BufRead, path::PathBuf};

use idevice::{
    IdeviceService,
    amfi::AmfiClient,
    house_arrest::HouseArrestClient,
    installation_proxy::InstallationProxyClient,
    lockdown::LockdownClient,
    provider::{IdeviceProvider, UsbmuxdProvider},
    remote_pairing::{RemotePairingLockdownService, RpPairingFile},
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection},
};
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{
        certificates::DevelopmentCertificate,
        developer_session::{DeveloperSession, DevicesApi, TeamsApi},
    },
    sideload::{
        SideloaderBuilder,
        builder::{ExtensionsBehavior, ExtensionsBehaviorSelection, MaxCertsBehavior},
    },
    util::{callbacks::ExtensionsBehaviorCallbackBox, fs_storage::FsStorage},
};
use rootcause::prelude::*;
use serde_json::{Value, json};

/// Name on the signing certificate, so people can tell it apart in their Apple account.
const MACHINE: &str = "GPS Spoofer";
const LABEL: &str = "gps-spoofer";

fn emit(v: Value) {
    println!("{v}");
}

/// A user-facing message plus the raw detail for the "Details" disclosure.
struct Fail(String, String);

impl Fail {
    fn new(msg: &str, detail: impl std::fmt::Debug) -> Self {
        Fail(msg.into(), format!("{detail:?}"))
    }
}

type Out = Result<Value, Fail>;

#[tokio::main]
async fn main() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let _ = isideload::init();

    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().cloned().unwrap_or_default();
    let flags = Flags(args);
    let res = match cmd.as_str() {
        "devices" => devices().await,
        "apps" => apps(&flags).await,
        "trust" => trust(&flags).await,
        "devmode" => devmode(&flags).await,
        "status" => status(&flags).await,
        "login" => login(&flags).await,
        "install" => install(&flags).await,
        _ => Err(Fail("Unknown command".into(), cmd)),
    };
    match res {
        Ok(mut v) => {
            v["ok"] = json!(true);
            emit(v);
        }
        Err(Fail(msg, details)) => {
            emit(json!({ "ok": false, "error": msg, "details": details }));
            std::process::exit(1);
        }
    }
}

struct Flags(Vec<String>);

impl Flags {
    fn get(&self, name: &str) -> Result<String, Fail> {
        let key = format!("--{name}");
        self.0
            .iter()
            .position(|a| *a == key)
            .and_then(|i| self.0.get(i + 1).cloned())
            .ok_or_else(|| Fail("Missing argument".into(), key))
    }
}

// MARK: phone

async fn mux() -> Result<UsbmuxdConnection, Fail> {
    UsbmuxdConnection::default()
        .await
        .map_err(|e| Fail::new("Couldn't talk to the Mac's iPhone service (usbmuxd).", e))
}

async fn provider(udid: &str) -> Result<UsbmuxdProvider, Fail> {
    let dev = mux()
        .await?
        .get_device(udid)
        .await
        .map_err(|e| Fail::new("Your iPhone isn't connected. Plug it in and unlock it.", e))?;
    Ok(dev.to_provider(UsbmuxdAddr::default(), LABEL))
}

async fn devices() -> Out {
    let list = mux()
        .await?
        .get_devices()
        .await
        .map_err(|e| Fail::new("Couldn't list iPhones.", e))?;
    let mut phones = Vec::new();
    for d in list.into_iter().filter(|d| d.connection_type == Connection::Usb) {
        let p = d.to_provider(UsbmuxdAddr::default(), LABEL);
        let Ok(mut lockdown) = LockdownClient::connect(&p).await else { continue };
        // DeviceName and DeviceClass are readable before the phone trusts the Mac.
        let value = |v: Result<plist::Value, _>| v.ok().and_then(|v| v.as_string().map(str::to_string));
        let name = value(lockdown.get_value(Some("DeviceName"), None).await).unwrap_or("iPhone".into());
        let class = value(lockdown.get_value(Some("DeviceClass"), None).await).unwrap_or_default();
        if !class.is_empty() && class != "iPhone" && class != "iPad" {
            continue;
        }
        let paired = match p.get_pairing_file().await {
            Ok(pf) => lockdown.start_session(&pf).await.is_ok(),
            Err(_) => false,
        };
        let mut version = None;
        let mut dev_mode = None;
        if paired {
            version = value(lockdown.get_value(Some("ProductVersion"), None).await);
            if let Ok(mut amfi) = AmfiClient::connect(&p).await {
                dev_mode = amfi.get_developer_mode_status().await.ok();
            }
        }
        phones.push(json!({
            "udid": d.udid, "name": name, "paired": paired, "devMode": dev_mode, "version": version,
        }));
    }
    Ok(json!({ "devices": phones }))
}

async fn apps(f: &Flags) -> Out {
    let p = provider(&f.get("udid")?).await?;
    let mut ip = InstallationProxyClient::connect(&p)
        .await
        .map_err(|e| Fail::new("Couldn't read the apps on your iPhone.", e))?;
    let found: HashMap<String, plist::Value> = ip
        .get_apps(Some("User"), None)
        .await
        .map_err(|e| Fail::new("Couldn't read the apps on your iPhone.", e))?;
    let apps: Vec<Value> = found
        .into_iter()
        .map(|(id, info)| {
            let d = info.as_dictionary();
            let s = |k: &str| d.and_then(|d| d.get(k)).and_then(|v| v.as_string()).map(str::to_string);
            json!({ "id": id, "name": s("CFBundleDisplayName").or(s("CFBundleName")) })
        })
        .collect();
    Ok(json!({ "apps": apps }))
}

/// Asks the phone to pair, which pops the Trust dialog. Succeeds once the user taps Trust.
async fn trust(f: &Flags) -> Out {
    let udid = f.get("udid")?;
    let p = provider(&udid).await?;
    let mut m = mux().await?;
    let buid = m.get_buid().await.map_err(|e| Fail::new("Couldn't reach usbmuxd.", e))?;
    let mut lockdown = LockdownClient::connect(&p)
        .await
        .map_err(|e| Fail::new("Couldn't reach your iPhone. Unlock it and try again.", e))?;
    let host_id = uuid_v4();
    let mut pf = lockdown
        .pair(host_id, buid, Some(MACHINE))
        .await
        .map_err(|e| Fail::new("Unlock your iPhone and tap Trust, then enter your passcode.", e))?;
    pf.udid = Some(udid.clone());
    let bytes = pf.serialize().map_err(|e| Fail::new("Couldn't save the pairing.", e))?;
    m.save_pair_record(&udid, bytes)
        .await
        .map_err(|e| Fail::new("Couldn't save the pairing.", e))?;
    Ok(json!({}))
}

async fn devmode(f: &Flags) -> Out {
    let p = provider(&f.get("udid")?).await?;
    let mut amfi = AmfiClient::connect(&p)
        .await
        .map_err(|e| Fail::new("Couldn't reach your iPhone.", e))?;
    amfi.reveal_developer_mode_option_in_ui()
        .await
        .map_err(|e| Fail::new("Couldn't show the Developer Mode switch.", e))?;
    Ok(json!({}))
}

async fn status(f: &Flags) -> Out {
    let p = provider(&f.get("udid")?).await?;
    let ha = HouseArrestClient::connect(&p)
        .await
        .map_err(|e| Fail::new("Couldn't reach the app.", e))?;
    let mut afc = ha
        .vend_container(f.get("bundle")?)
        .await
        .map_err(|e| Fail::new("Couldn't reach the app.", e))?;
    let mut file = afc
        .open("Documents/status.json", idevice::afc::opcode::AfcFopenMode::RdOnly)
        .await
        .map_err(|e| Fail::new("The app hasn't been opened yet.", e))?;
    let bytes = file
        .read_entire()
        .await
        .map_err(|e| Fail::new("Couldn't read the app's status.", e))?;
    let s: Value = serde_json::from_slice(&bytes).map_err(|e| Fail::new("Couldn't read the app's status.", e))?;
    Ok(json!({ "status": s }))
}

fn uuid_v4() -> String {
    let mut b = [0u8; 16];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = std::io::Read::read_exact(&mut f, &mut b);
    }
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h: String = b.iter().map(|x| format!("{x:02X}")).collect();
    format!("{}-{}-{}-{}-{}", &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..32])
}

// MARK: Apple account

struct Creds {
    email: String,
    password: String,
}

fn read_line() -> Option<Value> {
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line).ok()?;
    serde_json::from_str(line.trim()).ok()
}

fn read_creds() -> Result<Creds, Fail> {
    let v = read_line().ok_or_else(|| Fail("Missing Apple ID".into(), "stdin".into()))?;
    let s = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or_default().to_string();
    Ok(Creds { email: s("email"), password: s("password") })
}

/// Signs in, asking the window for a code (over stdout/stdin) when Apple wants two-factor.
async fn sign_in(data: &PathBuf, c: &Creds) -> Result<DeveloperSession, Fail> {
    let anisette = RemoteV3AnisetteProvider::default()
        .map_err(|e| Fail::new("Couldn't start Apple sign-in.", e))?
        .set_storage(Box::new(FsStorage::new(data.clone())));
    let two_factor = |p: TwoFactorCallbackParams| async move {
        emit(json!({ "need": "code", "sms": p.sms, "lastError": p.last_error }));
        let answer = tokio::task::spawn_blocking(read_line).await.ok().flatten();
        Ok::<_, Report>(match answer.as_ref().and_then(|a| a.get("code")).and_then(|c| c.as_str()) {
            Some(code) => TwoFactorCallbackResponse::SubmitCode(code.trim().to_string()),
            None => TwoFactorCallbackResponse::Abort,
        })
    };
    let mut account: AppleAccount = AppleAccount::builder(&c.email)
        .anisette_provider(anisette)
        .login(&c.password, two_factor)
        .await
        .map_err(|e| Fail::new(&sign_in_message(&format!("{e:?}")), e))?;
    DeveloperSession::from_account(&mut account)
        .await
        .map_err(|e| Fail::new("Signed in, but couldn't open your Apple developer account.", e))
}

fn sign_in_message(detail: &str) -> String {
    let t = detail.to_lowercase();
    if t.contains("-22406") || t.contains("-80002") || t.contains("incorrect") || t.contains("invalid") && t.contains("password") {
        "That Apple ID or password isn't right.".into()
    } else if t.contains("aborting") {
        "Sign-in cancelled.".into()
    } else if t.contains("-20209") || t.contains("locked") {
        "This Apple ID is locked. Unlock it at iforgot.apple.com, then try again.".into()
    } else if t.contains("-36607") || t.contains("not available") {
        "Apple didn't accept this sign-in right now. Wait a few minutes and try again.".into()
    } else {
        "Couldn't sign in to Apple. Check the Apple ID and password and your internet connection.".into()
    }
}

async fn login(f: &Flags) -> Out {
    let data = PathBuf::from(f.get("data")?);
    let creds = read_creds()?;
    let mut session = sign_in(&data, &creds).await?;
    let teams = session
        .list_teams()
        .await
        .map_err(|e| Fail::new("Signed in, but couldn't read your developer teams.", e))?;
    if teams.is_empty() {
        return Err(Fail::new(
            "This Apple ID has no developer team yet. Sign in once at developer.apple.com/account to accept the terms, then try again.",
            "no teams",
        ));
    }
    let teams: Vec<Value> = teams
        .iter()
        .map(|t| json!({ "id": t.team_id, "name": t.name.clone().unwrap_or(t.team_id.clone()), "type": t.r#type }))
        .collect();
    Ok(json!({ "teams": teams }))
}

// MARK: install

async fn install(f: &Flags) -> Out {
    let data = PathBuf::from(f.get("data")?);
    let udid = f.get("udid")?;
    let ipa = PathBuf::from(f.get("ipa")?);
    let team_id = f.get("team")?;
    let pairing = PathBuf::from(f.get("pairing")?);
    let creds = read_creds()?;

    let p = provider(&udid).await?;
    let name = {
        let mut l = LockdownClient::connect(&p)
            .await
            .map_err(|e| Fail::new("Couldn't reach your iPhone. Unlock it and try again.", e))?;
        l.get_value(Some("DeviceName"), None).await.ok().and_then(|v| v.as_string().map(str::to_string))
    }
    .unwrap_or("iPhone".into());

    emit(json!({ "stage": "Signing in to Apple…" }));
    let mut session = sign_in(&data, &creds).await?;
    let teams = session
        .list_teams()
        .await
        .map_err(|e| Fail::new("Couldn't read your developer teams.", e))?;
    let team = teams
        .into_iter()
        .find(|t| t.team_id == team_id)
        .ok_or_else(|| Fail::new("That team isn't on this Apple ID any more. Sign in again.", &team_id))?;

    emit(json!({ "stage": format!("Registering {name} with your Apple account…") }));
    session
        .ensure_device_registered(&team, &name, &udid, None)
        .await
        .map_err(|e| Fail::new(&developer_message(&format!("{e:?}")), e))?;

    // Only ever revoke certificates this app made; anything else belongs to other tools.
    let max_certs = |certs: Vec<DevelopmentCertificate>| async move {
        let ours: Vec<String> = certs
            .into_iter()
            .filter(|c| c.machine_name.as_deref() == Some(MACHINE))
            .filter_map(|c| c.serial_number)
            .collect();
        Ok::<_, Report>(if ours.is_empty() { None } else { Some(ours) })
    };
    let mut sideloader = SideloaderBuilder::<_, ExtensionsBehaviorCallbackBox>::new(session, creds.email.clone())
        .storage(Box::new(FsStorage::new(data.clone())))
        .machine_name(MACHINE.into())
        .max_certs_behavior(MaxCertsBehavior::Prompt(max_certs))
        .extensions_behavior(ExtensionsBehaviorSelection::Fixed(ExtensionsBehavior::ReuseMain))
        .build();

    emit(json!({ "stage": "Signing GPS Spoofer with your Apple account…" }));
    let (signed, _) = sideloader
        .sign_app(
            ipa,
            Some(team.clone()),
            false,
            Some(|p: f32| async move { emit(json!({ "progress": p * 0.5 })) }),
            None,
            Some(&udid),
        )
        .await
        .map_err(|e| Fail::new(&developer_message(&format!("{e:?}")), e))?;
    let bundle = read_bundle_id(&signed).unwrap_or_default();
    let expiry = profile_expiry(&signed.join("embedded.mobileprovision"));

    emit(json!({ "stage": format!("Installing on {name}…"), "progress": 0.5 }));
    let result = isideload::sideload::install::install_app(&p, &signed, |pct| {
        emit(json!({ "progress": 0.5 + pct as f64 / 200.0 }))
    })
    .await;
    let _ = std::fs::remove_dir_all(&signed);
    result.map_err(|e| Fail::new(&install_message(&format!("{e:?}")), e))?;

    emit(json!({ "stage": format!("Pairing GPS Spoofer with {name}…"), "progress": serde_json::Value::Null }));
    if !pairing.exists() {
        let service = RemotePairingLockdownService::connect(&p)
            .await
            .map_err(|e| Fail::new("Couldn't pair with your iPhone. Unlock it, keep it plugged in, and try again.", e))?;
        let mut client = service
            .into_client(MACHINE)
            .map_err(|e| Fail::new("Couldn't pair with your iPhone.", e))?;
        let mut pf = RpPairingFile::generate(MACHINE);
        // Over the already-trusted cable there's no PIN prompt, so this never fires.
        client
            .connect(&mut pf, async || "000000".to_string())
            .await
            .map_err(|e| Fail::new("Couldn't pair with your iPhone. Unlock it, keep it plugged in, and try again.", e))?;
        pf.write_to_file(&pairing)
            .await
            .map_err(|e| Fail::new("Couldn't save the pairing.", e))?;
    }
    let bytes = std::fs::read(&pairing).map_err(|e| Fail::new("Couldn't read the pairing.", e))?;
    let ha = HouseArrestClient::connect(&p)
        .await
        .map_err(|e| Fail::new("Couldn't finish pairing. Try again.", e))?;
    let mut afc = ha
        .vend_container(bundle.clone())
        .await
        .map_err(|e| Fail::new("Couldn't finish pairing. Try again.", e))?;
    let _ = afc.mk_dir("Documents").await;
    let mut file = afc
        .open("Documents/pairing.plist", idevice::afc::opcode::AfcFopenMode::WrOnly)
        .await
        .map_err(|e| Fail::new("Couldn't finish pairing. Try again.", e))?;
    file.write_entire(&bytes)
        .await
        .map_err(|e| Fail::new("Couldn't finish pairing. Try again.", e))?;
    let _ = file.close().await;

    Ok(json!({ "bundle": bundle, "expiry": expiry, "free": team.r#type.as_deref() != Some("Company/Organization") && expiry_days(&expiry) < 8.0 }))
}

fn read_bundle_id(app: &PathBuf) -> Option<String> {
    let v = plist::Value::from_file(app.join("Info.plist")).ok()?;
    v.as_dictionary()?.get("CFBundleIdentifier")?.as_string().map(str::to_string)
}

/// The profile's ExpirationDate (ISO 8601): when the app stops opening.
fn profile_expiry(path: &PathBuf) -> Option<String> {
    let data = std::fs::read(path).ok()?;
    let start = find(&data, b"<?xml")?;
    let end = find(&data, b"</plist>")? + b"</plist>".len();
    let v = plist::Value::from_reader_xml(&data[start..end]).ok()?;
    let d = v.as_dictionary()?.get("ExpirationDate")?.as_date()?;
    Some(d.to_xml_format())
}

fn expiry_days(expiry: &Option<String>) -> f64 {
    let Some(e) = expiry else { return f64::INFINITY };
    let Ok(d) = plist::Date::from_xml_format(e) else { return f64::INFINITY };
    let t: std::time::SystemTime = d.into();
    t.duration_since(std::time::SystemTime::now()).map(|d| d.as_secs_f64() / 86400.0).unwrap_or(0.0)
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

fn developer_message(detail: &str) -> String {
    let t = detail.to_lowercase();
    if t.contains("maximum number of apps") || t.contains("too many") && t.contains("app id") {
        "Free Apple accounts can register 10 app IDs a week. Wait a few days, or use a paid developer account.".into()
    } else if t.contains("certificate") && (t.contains("maximum") || t.contains("max")) {
        "Your Apple account already has the most signing certificates it can. Revoke one at developer.apple.com/account › Certificates, then try again.".into()
    } else if t.contains("agreement") || t.contains("terms") {
        "Apple has new developer terms for this Apple ID. Sign in at developer.apple.com/account, accept them, then try again.".into()
    } else {
        "Apple wouldn't sign the app with this account. Try again, or sign in again.".into()
    }
}

fn install_message(detail: &str) -> String {
    let t = detail.to_lowercase();
    if t.contains("applicationverificationfailed") && t.contains("maximum") || t.contains("3 apps") {
        "Free Apple accounts can have 3 developer apps on a phone at once. Delete one, then try again.".into()
    } else if t.contains("developer mode") || t.contains("devicenotsupported") {
        "Developer Mode is off on your iPhone. Turn it on and try again.".into()
    } else if t.contains("locked") || t.contains("passwordprotected") {
        "Your iPhone is locked. Unlock it and try again.".into()
    } else {
        "Couldn't install on your iPhone. Unlock it, keep it plugged in, and try again.".into()
    }
}
