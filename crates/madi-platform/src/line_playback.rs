//! Main-thread-only ownership of the shipping AVPlayer line playback adapter.
//! Paths stay native-owned; callers must retire playback on session replacement.
use madi_core::transcript::Uuid;
use std::{ffi::c_void, marker::PhantomData, path::Path, ptr::NonNull, rc::Rc};

type Changed = Box<dyn Fn(Option<Uuid>)>;
unsafe extern "C" {
    fn madi_playback_create(
        context: *mut c_void,
        changed: extern "C" fn(*mut c_void, *const u8, usize),
    ) -> *mut c_void;
    fn madi_playback_toggle(
        handle: *mut c_void,
        path: *const u8,
        path_len: usize,
        line: *const u8,
        line_len: usize,
        from: f64,
        to: f64,
    ) -> i32;
    fn madi_playback_stop(handle: *mut c_void);
    fn madi_playback_destroy(handle: *mut c_void);
}
extern "C" fn changed(context: *mut c_void, bytes: *const u8, len: usize) {
    // Swift owns the transient bytes and invokes this synchronously on main.
    // The boxed callback outlives the endpoint, including its final stop event.
    let callback = unsafe { &*(context.cast::<Changed>()) };
    let current = if len == 0 {
        None
    } else {
        let bytes = unsafe { std::slice::from_raw_parts(bytes, len) };
        std::str::from_utf8(bytes)
            .ok()
            .and_then(|s| Uuid::parse_str(s).ok())
    };
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| callback(current)));
}
pub struct Player {
    handle: NonNull<c_void>,
    // Stable outer allocation points to a fat Rust callback. It must be dropped
    // only after Swift destroys its observation owner and stops AVPlayer.
    _changed: Box<Changed>,
    _main_thread: PhantomData<Rc<()>>,
}
impl Player {
    pub fn new(callback: impl Fn(Option<Uuid>) + 'static) -> Result<Self, &'static str> {
        let mut callback: Box<Changed> = Box::new(Box::new(callback));
        let context = (&mut *callback as *mut Changed).cast::<c_void>();
        let handle = NonNull::new(unsafe { madi_playback_create(context, changed) })
            .ok_or("playback must be created on the main thread")?;
        Ok(Self {
            handle,
            _changed: callback,
            _main_thread: PhantomData,
        })
    }
    pub fn toggle(
        &mut self,
        path: &Path,
        line: Uuid,
        from: f64,
        to: f64,
    ) -> Result<(), &'static str> {
        if !from.is_finite() || !to.is_finite() {
            return Err("invalid playback span");
        }
        let path = path.to_str().ok_or("unsupported playback path")?;
        let line = line.to_string();
        let accepted = unsafe {
            madi_playback_toggle(
                self.handle.as_ptr(),
                path.as_ptr(),
                path.len(),
                line.as_ptr(),
                line.len(),
                from,
                to,
            )
        };
        if accepted == 1 {
            Ok(())
        } else {
            Err("native playback request rejected")
        }
    }
    pub fn stop(&mut self) {
        unsafe { madi_playback_stop(self.handle.as_ptr()) }
    }
}
impl Drop for Player {
    fn drop(&mut self) {
        unsafe { madi_playback_destroy(self.handle.as_ptr()) }
    }
}
