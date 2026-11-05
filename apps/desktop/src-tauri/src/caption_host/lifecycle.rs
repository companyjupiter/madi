//! Instance ownership survives async native destruction without reusing a
//! retiring window label or accepting late IPC from the previous WebView.
use madi_core::{caption::Audience, transcript::Uuid};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    Show(String),
    Hide,
    Release,
}
struct Instance {
    generation: String,
    retiring: bool,
}
#[derive(Default)]
pub struct Windows {
    staff: Option<Instance>,
    patient: Option<Instance>,
}
impl Windows {
    fn slot(&self, audience: Audience) -> &Option<Instance> {
        match audience {
            Audience::Staff => &self.staff,
            Audience::Patient => &self.patient,
        }
    }
    fn slot_mut(&mut self, audience: Audience) -> &mut Option<Instance> {
        match audience {
            Audience::Staff => &mut self.staff,
            Audience::Patient => &mut self.patient,
        }
    }
    pub fn generation(&self, audience: Audience) -> Option<&str> {
        self.slot(audience)
            .as_ref()
            .filter(|i| !i.retiring)
            .map(|i| i.generation.as_str())
    }
    pub fn accepts(&self, audience: Audience, generation: &str) -> bool {
        self.generation(audience) == Some(generation)
    }
    pub fn action(&mut self, audience: Audience, overlay: bool, patient_enabled: bool) -> Action {
        if !overlay {
            return Action::Hide;
        }
        if audience == Audience::Patient && !patient_enabled {
            return self.release(audience);
        }
        let slot = self.slot_mut(audience).get_or_insert_with(|| Instance {
            generation: Uuid::new_v4().to_string(),
            retiring: false,
        });
        if slot.retiring {
            Action::Hide
        } else {
            Action::Show(slot.generation.clone())
        }
    }
    pub fn release(&mut self, audience: Audience) -> Action {
        if let Some(slot) = self.slot_mut(audience).as_mut()
            && !slot.retiring
        {
            slot.retiring = true;
            Action::Release
        } else {
            Action::Hide
        }
    }
    /// None means no owned instance; false means an unexpected native close.
    pub fn destroyed(&mut self, audience: Audience) -> Option<bool> {
        self.slot_mut(audience).take().map(|i| i.retiring)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn disabling_patient_releases_once_and_waits_for_destroy_before_recreating() {
        let mut windows = Windows::default();
        let Action::Show(old) = windows.action(Audience::Patient, true, true) else {
            panic!()
        };
        assert!(windows.accepts(Audience::Patient, &old));
        assert_eq!(
            windows.action(Audience::Patient, true, false),
            Action::Release
        );
        assert!(
            !windows.accepts(Audience::Patient, &old),
            "old resize/close/snapshot IPC retires immediately"
        );
        assert_eq!(windows.action(Audience::Patient, true, false), Action::Hide);
        assert_eq!(
            windows.action(Audience::Patient, true, true),
            Action::Hide,
            "do not reuse a retiring native label"
        );
        assert_eq!(windows.destroyed(Audience::Patient), Some(true));
        let Action::Show(new) = windows.action(Audience::Patient, true, true) else {
            panic!()
        };
        assert_ne!(old, new);
        assert!(!windows.accepts(Audience::Patient, &old));
        assert!(windows.accepts(Audience::Patient, &new));
        assert!(!windows.accepts(Audience::Staff, &new));
    }
    #[test]
    fn hiding_the_overlay_preserves_both_instances_and_source_settings_take_effect_on_show() {
        let mut windows = Windows::default();
        let staff = windows.action(Audience::Staff, true, true);
        let patient = windows.action(Audience::Patient, true, true);
        assert_eq!(windows.action(Audience::Staff, false, false), Action::Hide);
        assert_eq!(
            windows.action(Audience::Patient, false, false),
            Action::Hide
        );
        assert_eq!(windows.action(Audience::Staff, true, true), staff);
        assert_eq!(windows.action(Audience::Patient, true, true), patient);
        assert_eq!(
            windows.action(Audience::Patient, true, false),
            Action::Release
        );
        assert_eq!(windows.action(Audience::Staff, true, false), staff);
    }
    #[test]
    fn unexpected_native_destruction_is_distinguishable_from_requested_release() {
        let mut windows = Windows::default();
        assert_eq!(windows.destroyed(Audience::Staff), None);
        windows.action(Audience::Staff, true, false);
        assert_eq!(windows.destroyed(Audience::Staff), Some(false));
        assert_eq!(windows.generation(Audience::Staff), None);
    }
}
