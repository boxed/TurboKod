//! Native macOS menu bar (NSMenu).
//!
//! winit installs no menu, so the system menu bar shows only the bold app
//! name with nothing under it. This adds a minimal main menu:
//!
//!   * the app menu (TurboKod) with **Quit** (⌘Q → standard `terminate:`)
//!   * a **File** menu with **New Window** (⌘N)
//!
//! "New Window" can't just be a key-equivalent with no action: once a menu
//! item owns ⌘N, macOS routes ⌘N to the menu *before* winit sees it as a key
//! event — so a dead item would silently swallow the shortcut. Instead the
//! item targets a tiny custom NSObject whose action bumps a global counter;
//! `tk_app_pump` drains it into `EV_NEW_WINDOW` events for the Mojo loop,
//! which spawns the new Desktop (the same path ⌘N took before the menu
//! existed).

use std::sync::atomic::{AtomicU32, Ordering};

use objc2::declare_class;
use objc2::mutability;
use objc2::rc::Retained;
use objc2::runtime::{AnyObject, NSObject};
use objc2::{msg_send_id, sel, ClassType, DeclaredClass};
use objc2_app_kit::{NSApplication, NSMenu, NSMenuItem};
use objc2_foundation::{MainThreadMarker, NSString};

/// Incremented on the main thread by the "New Window" menu action; drained
/// by `pending_new_windows()` in the pump.
static NEW_WINDOW_REQUESTS: AtomicU32 = AtomicU32::new(0);

/// Drain and return the number of New-Window requests since the last call.
pub fn pending_new_windows() -> u32 {
    NEW_WINDOW_REQUESTS.swap(0, Ordering::SeqCst)
}

declare_class!(
    struct MenuTarget;

    unsafe impl ClassType for MenuTarget {
        type Super = NSObject;
        type Mutability = mutability::InteriorMutable;
        const NAME: &'static str = "TkMenuTarget";
    }

    impl DeclaredClass for MenuTarget {}

    unsafe impl MenuTarget {
        #[method(tkNewWindow:)]
        fn tk_new_window(&self, _sender: Option<&AnyObject>) {
            NEW_WINDOW_REQUESTS.fetch_add(1, Ordering::SeqCst);
        }
    }
);

impl MenuTarget {
    fn new() -> Retained<Self> {
        unsafe { msg_send_id![Self::alloc(), init] }
    }
}

/// Install the main menu once. The action target is leaked (kept alive for
/// the process lifetime) because NSMenuItem references its target weakly —
/// there is exactly one menu for the whole app, so this is a fixed one-time
/// cost, not a growing leak.
pub fn install_main_menu() {
    let target = build_menu();
    std::mem::forget(target);
}

fn build_menu() -> Retained<MenuTarget> {
    let mtm = MainThreadMarker::new().expect("menu install must run on main thread");
    let target = MenuTarget::new();
    let app = NSApplication::sharedApplication(mtm);
    let main_menu = NSMenu::new(mtm);

    // App menu: its title is ignored by the system (it shows the bundle
    // name, "TurboKod"). We just need a submenu to hang Quit on.
    let app_item = NSMenuItem::new(mtm);
    let app_menu = NSMenu::new(mtm);
    let quit = unsafe {
        NSMenuItem::initWithTitle_action_keyEquivalent(
            mtm.alloc::<NSMenuItem>(),
            &NSString::from_str("Quit TurboKod"),
            Some(sel!(terminate:)),
            &NSString::from_str("q"),
        )
    };
    app_menu.addItem(&quit);
    app_item.setSubmenu(Some(&app_menu));
    main_menu.addItem(&app_item);

    // File menu with New Window (⌘N). A lowercase single-char key equivalent
    // implies the Command modifier.
    let file_item = NSMenuItem::new(mtm);
    let file_menu = NSMenu::new(mtm);
    unsafe { file_menu.setTitle(&NSString::from_str("File")) };
    let new_window = unsafe {
        NSMenuItem::initWithTitle_action_keyEquivalent(
            mtm.alloc::<NSMenuItem>(),
            &NSString::from_str("New Window"),
            Some(sel!(tkNewWindow:)),
            &NSString::from_str("n"),
        )
    };
    unsafe { new_window.setTarget(Some(&target)) };
    file_menu.addItem(&new_window);
    file_item.setSubmenu(Some(&file_menu));
    main_menu.addItem(&file_item);

    app.setMainMenu(Some(&main_menu));
    target
}
