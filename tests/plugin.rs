use std::path::Path;
use std::sync::Arc;

use maki_agent::tools::ToolRegistry;
use maki_lua::test_support::runtime;
use maki_lua::{PluginHost, PluginPermissions};
use maki_providers::{Timeouts, plugin};
use maki_storage::StateDir;
use maki_storage::auth::save_plugin_auth;
use serde_json::json;

const PLUGIN_NAME: &str = "maki-claude";
const SLUG: &str = "claude";
const DISPLAY_NAME: &str = "Claude subscription";
const NET_HOST: &str = "api.anthropic.com";
const ACCESS: &str = "access-token";
const FAR_FUTURE_S: u64 = 4102444800;
const LOGIN_HINT: &str = "maki auth login claude";
const BROKEN_HOOK: &str = "hook failed";
const SUPPORTED_SYSTEMS: &str = "Windows, Linux and macOS";

/// The provider registry and the environment are global, so every test leans
/// on nextest running it in a process of its own.
fn plugin_host() -> PluginHost {
    let dir = std::env::temp_dir().join(format!("maki-claude-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    for var in [
        "HOME",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_STATE_HOME",
        "XDG_CACHE_HOME",
    ] {
        unsafe { std::env::set_var(var, &dir) };
    }
    let host = PluginHost::new(Arc::new(ToolRegistry::new())).unwrap();
    let mut permissions = PluginPermissions::from_approved(["net", "run", "env"]);
    permissions.set_net_hosts(Some(Arc::from(vec![NET_HOST.to_owned()])));
    host.load_package(
        PLUGIN_NAME,
        Path::new(env!("CARGO_MANIFEST_DIR")),
        permissions,
        Default::default(),
    )
    .unwrap();
    plugin::commit_load();
    host
}

/// What the `auth` hook answers when nothing is stored.
fn auth_error_without_a_login() -> String {
    let _host = plugin_host();
    let failure = match plugin::create(SLUG, Timeouts::default()) {
        Ok(provider) => runtime().block_on(provider.reload_auth()).unwrap_err(),
        Err(err) => err,
    };
    failure.to_string()
}

#[test]
fn registers_a_login_provider() {
    let _host = plugin_host();
    assert!(plugin::auth_providers().contains(&(SLUG.to_owned(), DISPLAY_NAME.to_owned())));
}

#[test]
fn a_stored_token_becomes_the_bearer_header() {
    let _host = plugin_host();
    let creds = json!({ "access": ACCESS, "refresh": "refresh-token", "expires": FAR_FUTURE_S });
    save_plugin_auth(
        &StateDir::resolve().unwrap(),
        SLUG,
        creds.as_object().unwrap(),
    )
    .unwrap();

    let provider = plugin::create(SLUG, Timeouts::default()).unwrap();
    runtime().block_on(provider.reload_auth()).unwrap();

    let headers = plugin::resolved_auth(SLUG).unwrap().headers;
    assert!(
        headers
            .iter()
            .any(|(k, v)| k.eq_ignore_ascii_case("authorization")
                && v == &format!("Bearer {ACCESS}")),
        "{headers:?}"
    );
}

#[test]
fn auth_without_a_login_names_the_login_command() {
    let message = auth_error_without_a_login();
    assert!(message.contains(LOGIN_HINT), "{message}");
    assert!(!message.contains(BROKEN_HOOK), "{message}");
}

#[cfg(unix)]
#[test]
fn auth_without_a_login_on_another_system_names_the_supported_ones() {
    use std::os::unix::fs::PermissionsExt;

    let bin = std::env::temp_dir().join(format!("maki-claude-bin-{}", std::process::id()));
    std::fs::create_dir_all(&bin).unwrap();
    let uname = bin.join("uname");
    std::fs::write(&uname, "#!/bin/sh\necho FreeBSD\n").unwrap();
    std::fs::set_permissions(uname, std::fs::Permissions::from_mode(0o755)).unwrap();
    unsafe {
        std::env::remove_var("OS");
        std::env::set_var("PATH", bin);
    }
    let message = auth_error_without_a_login();
    assert!(message.contains(SUPPORTED_SYSTEMS), "{message}");
    assert!(!message.contains(BROKEN_HOOK), "{message}");
}
