// vayu-lal-compat: ABI shim for the 26.04 daily packages (2026-11).
// liblomiri-app-launch 0.2.0 dropped lomiri_app_launch_start_session_helper() without a
// soname bump, but lomiri-url-dispatcher 0.1.5 still links it -> "undefined symbol" at
// startup, so no settings:// or other URL can be opened (indicator "Bluetooth settings" etc.).
// Preloaded into lomiri-url-dispatcher only; forwards to lomiri_app_launch_start_helper()
// and ignores the Mir prompt session (only used for trusted-helper overlays).
// Build: aarch64-linux-gnu-gcc -shared -fPIC -O2 -o libvayu-lal-compat.so vayu-lal-compat.c
typedef char gchar;

extern gchar *lomiri_app_launch_start_helper(const gchar *type, const gchar *appid,
                                             const gchar *const *uris);

__attribute__((visibility("default")))
gchar *lomiri_app_launch_start_session_helper(const gchar *type, void *session,
                                              const gchar *appid, const gchar *const *uris)
{
    (void)session;
    return lomiri_app_launch_start_helper(type, appid, uris);
}
