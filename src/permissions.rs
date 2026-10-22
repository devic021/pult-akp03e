//! Whether macOS lets us synthesise keystrokes.
//!
//! Sending a keystroke needs Accessibility, and the permission attaches to the
//! *responsible* process, not to this binary: started from a terminal that is
//! the terminal app, started by `launchd` it is this binary. Guessing which one
//! is a losing game, so we let macOS name it in its own dialog.

use core_foundation::base::TCFType;
use core_foundation::boolean::CFBoolean;
use core_foundation::dictionary::{CFDictionary, CFDictionaryRef};
use core_foundation::string::{CFString, CFStringRef};

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrustedWithOptions(options: CFDictionaryRef) -> bool;
    static kAXTrustedCheckOptionPrompt: CFStringRef;
}

/// Reports whether this process may send keystrokes.
///
/// With `prompt`, macOS shows its "allow accessibility" dialog, naming the app
/// that has to be ticked. It shows that dialog once per app, so a second call
/// just answers the question.
pub fn accessibility_trusted(prompt: bool) -> bool {
    unsafe {
        let key = CFString::wrap_under_get_rule(kAXTrustedCheckOptionPrompt);
        let options = CFDictionary::from_CFType_pairs(&[(
            key.as_CFType(),
            CFBoolean::from(prompt).as_CFType(),
        )]);

        AXIsProcessTrustedWithOptions(options.as_concrete_TypeRef())
    }
}
