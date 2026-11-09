//! Main-thread-owned AppKit Settings toolbar. No native object crosses threads.
use objc2::{
    DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send, rc::Retained,
    runtime::ProtocolObject, sel,
};
use objc2_app_kit::{
    NSImage, NSToolbar, NSToolbarDelegate, NSToolbarDisplayMode, NSToolbarItem,
    NSToolbarItemIdentifier, NSWindow, NSWindowToolbarStyle,
};
use objc2_foundation::{NSArray, NSObject, NSObjectProtocol, NSString};
use std::{
    cell::{Cell, RefCell},
    ffi::c_void,
};

const TABS: [(&str, &str); 5] = [
    ("recording", "mic"),
    ("save", "square.and.arrow.down"),
    ("translation", "character.bubble"),
    ("glossary", "character.book.closed"),
    ("model", "shippingbox"),
];
type Selection = Box<dyn Fn(&str)>;
struct State {
    labels: RefCell<[String; 5]>,
    visible: Vec<usize>,
    revision: Cell<u64>,
    changed: Selection,
}
define_class!(
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "MadiSettingsToolbarDelegate"]
    #[ivars = State]
    struct Delegate;
    unsafe impl NSObjectProtocol for Delegate {}
    unsafe impl NSToolbarDelegate for Delegate {
        #[unsafe(method_id(toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:))]
        fn item(&self, _toolbar: &NSToolbar, identifier: &NSToolbarItemIdentifier, _insert: bool) -> Option<Retained<NSToolbarItem>> {
            self.make_item(identifier)
        }
        #[unsafe(method_id(toolbarDefaultItemIdentifiers:))]
        fn defaults(&self, _toolbar: &NSToolbar) -> Retained<NSArray<NSToolbarItemIdentifier>> { self.identifiers() }
        #[unsafe(method_id(toolbarAllowedItemIdentifiers:))]
        fn allowed(&self, _toolbar: &NSToolbar) -> Retained<NSArray<NSToolbarItemIdentifier>> { self.identifiers() }
        #[unsafe(method_id(toolbarSelectableItemIdentifiers:))]
        fn selectable(&self, _toolbar: &NSToolbar) -> Retained<NSArray<NSToolbarItemIdentifier>> { self.identifiers() }
    }
    impl Delegate {
        #[unsafe(method(selectSettingsTab:))]
        fn select(&self, sender: &NSToolbarItem) {
            if let Some(index) = TABS.iter().position(|(id, _)| *id == sender.itemIdentifier().to_string()) {
                if let Some(toolbar) = sender.toolbar() {
                    toolbar.setSelectedItemIdentifier(Some(&sender.itemIdentifier()));
                }
                (self.ivars().changed)(TABS[index].0);
            }
        }
    }
);
impl Delegate {
    fn make_item(&self, identifier: &NSToolbarItemIdentifier) -> Option<Retained<NSToolbarItem>> {
        let index = TABS
            .iter()
            .position(|(id, _)| *id == identifier.to_string())?;
        if !self.ivars().visible.contains(&index) {
            return None;
        }
        let item =
            NSToolbarItem::initWithItemIdentifier(NSToolbarItem::alloc(self.mtm()), identifier);
        let label = NSString::from_str(&self.ivars().labels.borrow()[index]);
        item.setLabel(&label);
        item.setPaletteLabel(&label);
        let image = NSImage::imageWithSystemSymbolName_accessibilityDescription(
            &NSString::from_str(TABS[index].1),
            None,
        );
        item.setImage(image.as_deref());
        // The main-thread owner retains this target for the toolbar's lifetime.
        unsafe {
            item.setTarget(Some(self));
            item.setAction(Some(sel!(selectSettingsTab:)));
        }
        Some(item)
    }
    fn identifiers(&self) -> Retained<NSArray<NSToolbarItemIdentifier>> {
        let ids: Vec<_> = self
            .ivars()
            .visible
            .iter()
            .map(|index| NSString::from_str(TABS[*index].0))
            .collect();
        NSArray::from_retained_slice(&ids)
    }
}
struct ToolbarOwner {
    window: Retained<NSWindow>,
    toolbar: Retained<NSToolbar>,
    delegate: Retained<Delegate>,
}
impl Drop for ToolbarOwner {
    fn drop(&mut self) {
        self.window.setToolbar(None);
        self.toolbar.setDelegate(None);
    }
}
thread_local! { static OWNER: RefCell<Option<ToolbarOwner>> = const { RefCell::new(None) }; }

/// Install once, then refresh localized labels without recreating selection.
///
/// # Safety
/// `window` is a live NSWindow owned by the caller on the main thread.
pub unsafe fn configure(
    window: *mut c_void,
    labels: [String; 5],
    translation: bool,
    revision: u64,
    changed: Selection,
) -> Result<(), &'static str> {
    let main = MainThreadMarker::new().ok_or("toolbar requires the main thread")?;
    let window = unsafe { Retained::retain(window.cast::<NSWindow>()) }
        .ok_or("settings window unavailable")?;
    OWNER.with(|slot| {
        let mut owner = slot.borrow_mut();
        if owner.is_none() {
            let state = State {
                labels: RefCell::new(labels.clone()),
                visible: (0..5).filter(|index| *index != 2 || translation).collect(),
                revision: Cell::new(revision),
                changed,
            };
            let delegate = Delegate::alloc(main).set_ivars(state);
            let delegate: Retained<Delegate> = unsafe { msg_send![super(delegate), init] };
            let toolbar = NSToolbar::initWithIdentifier(
                NSToolbar::alloc(main),
                &NSString::from_str("madi.settings"),
            );
            toolbar.setDelegate(Some(ProtocolObject::from_ref(&*delegate)));
            toolbar.setDisplayMode(NSToolbarDisplayMode::IconAndLabel);
            toolbar.setAllowsUserCustomization(false);
            toolbar.setAutosavesConfiguration(false);
            let mut frame = window.frame();
            frame.size.width = 492.0;
            frame.size.height = 500.0;
            window.setToolbarStyle(NSWindowToolbarStyle::Preference);
            window.setToolbar(Some(&toolbar));
            toolbar.setSelectedItemIdentifier(Some(&NSString::from_str("recording")));
            // Match the original outer frame; installing AppKit chrome changes
            // the content layout, not the 492 x 500 point Settings window.
            window.setFrame_display(frame, false);
            *owner = Some(ToolbarOwner {
                window,
                toolbar,
                delegate,
            });
        }
        let owner = owner.as_ref().expect("installed");
        let state = owner.delegate.ivars();
        if revision >= state.revision.get() {
            state.revision.set(revision);
            *state.labels.borrow_mut() = labels;
            let items = owner.toolbar.items();
            for index in 0..items.count() {
                let item = items.objectAtIndex(index);
                if let Some(index) = TABS
                    .iter()
                    .position(|(id, _)| *id == item.itemIdentifier().to_string())
                {
                    let label = NSString::from_str(&state.labels.borrow()[index]);
                    item.setLabel(&label);
                    item.setPaletteLabel(&label);
                }
            }
        }
    });
    Ok(())
}

pub fn shutdown() {
    if MainThreadMarker::new().is_some() {
        OWNER.with(|slot| {
            slot.borrow_mut().take();
        });
    }
}
