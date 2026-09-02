use crate::{
    config::{GestureKey, ResolvedGestureBindings},
    protocol::{DisplayEdge, InputEvent},
};
use anyhow::{Context, Result};
use evdev::{
    AttributeSet, EventType, InputEvent as LinuxEvent, KeyCode, RelativeAxisCode,
    uinput::VirtualDevice,
};
use std::collections::BTreeSet;

pub trait InputSink: Send {
    fn activate(
        &mut self,
        width: f64,
        height: f64,
        edge: DisplayEdge,
        normalized_position: f64,
    ) -> Result<()>;
    fn inject(&mut self, event: &InputEvent) -> Result<()>;
    fn release_all(&mut self) -> Result<()>;
}

pub struct UinputSink {
    device: VirtualDevice,
    held: BTreeSet<KeyCode>,
    modifiers: u16,
    swipe_triggered: bool,
    gesture_bindings: ResolvedGestureBindings,
}

impl UinputSink {
    pub fn open(gesture_bindings: ResolvedGestureBindings) -> Result<Self> {
        let mut keys = AttributeSet::<KeyCode>::new();
        for code in 1..=248 {
            keys.insert(KeyCode::new(code));
        }
        // Mouse buttons live above the keyboard range (BTN_LEFT = 0x110);
        // without advertising them the kernel drops every click event.
        for code in [0x110, 0x111, 0x112, 0x113, 0x114, 0x115, 0x116] {
            keys.insert(KeyCode::new(code));
        }
        let mut relative = AttributeSet::<RelativeAxisCode>::new();
        for axis in [
            RelativeAxisCode::REL_X,
            RelativeAxisCode::REL_Y,
            RelativeAxisCode::REL_WHEEL,
            RelativeAxisCode::REL_HWHEEL,
        ] {
            relative.insert(axis);
        }
        let device = VirtualDevice::builder()
            .context("open /dev/uinput; add your user to the unispace group and sign in again")?
            .name("UniSpace Virtual Input")
            .with_keys(&keys)?
            .with_relative_axes(&relative)?
            .build()?;
        Ok(Self {
            device,
            held: BTreeSet::new(),
            modifiers: 0,
            swipe_triggered: false,
            gesture_bindings,
        })
    }
    fn emit(&mut self, events: &[LinuxEvent]) -> Result<()> {
        self.device.emit(events)?;
        Ok(())
    }
    fn key(&mut self, key: KeyCode, down: bool) -> Result<()> {
        if down {
            self.held.insert(key);
        } else {
            self.held.remove(&key);
        }
        self.emit(&[LinuxEvent::new(
            EventType::KEY.0,
            key.code(),
            u16::from(down) as i32,
        )])
    }
    fn chord(&mut self, keys: &[KeyCode]) -> Result<()> {
        for key in keys {
            self.key(*key, true)?
        }
        for key in keys.iter().rev() {
            self.key(*key, false)?
        }
        Ok(())
    }
    fn gesture_chord(&mut self, keys: &[GestureKey]) -> Result<()> {
        self.chord(
            &keys
                .iter()
                .copied()
                .map(gesture_key_code)
                .collect::<Vec<_>>(),
        )
    }
    fn update_modifiers(&mut self, next: u16) -> Result<()> {
        for (bit, key) in [
            (0, KeyCode::KEY_LEFTSHIFT),
            (1, KeyCode::KEY_LEFTCTRL),
            (2, KeyCode::KEY_LEFTALT),
            (3, KeyCode::KEY_LEFTMETA),
            (4, KeyCode::KEY_CAPSLOCK),
        ] {
            let mask = 1u16 << bit;
            if (self.modifiers & mask) != (next & mask) {
                self.key(key, next & mask != 0)?
            }
        }
        self.modifiers = next;
        Ok(())
    }
    /// Gesture phases mirror the Windows injector: swipe/desktop-pinch
    /// shortcuts fire once per gesture once the accumulated delta crosses a
    /// threshold, resetting on begin/cancel/end.
    fn gesture(&mut self, kind: u8, phase: u8, dx: f64, dy: f64, value: f64) -> Result<()> {
        const PHASE_MAY_BEGIN: u8 = 1;
        const PHASE_BEGAN: u8 = 2;
        const PHASE_ENDED: u8 = 4;
        const PHASE_CANCELLED: u8 = 5;
        match kind {
            1 => {
                self.key(KeyCode::KEY_LEFTCTRL, true)?;
                self.wheel(0.0, value * 8.0)?;
                self.key(KeyCode::KEY_LEFTCTRL, false)
            }
            2 | 7 => {
                if phase == PHASE_MAY_BEGIN || phase == PHASE_BEGAN {
                    self.swipe_triggered = false;
                }
                if phase == PHASE_CANCELLED {
                    self.swipe_triggered = false;
                    return Ok(());
                }
                let horizontal = dx.abs() >= dy.abs();
                let distance = if horizontal { dx.abs() } else { dy.abs() };
                if !self.swipe_triggered && distance >= 1.0 {
                    if kind == 7 {
                        let binding = if horizontal && dx > 0.0 {
                            self.gesture_bindings.workspace_previous.clone()
                        } else if horizontal {
                            self.gesture_bindings.workspace_next.clone()
                        } else if dy > 0.0 {
                            self.gesture_bindings.workspace_up.clone()
                        } else {
                            self.gesture_bindings.workspace_down.clone()
                        };
                        if let Some(binding) = binding {
                            self.gesture_chord(&binding)?
                        }
                    } else {
                        let binding = if dx > 0.0 {
                            self.gesture_bindings.navigation_back.clone()
                        } else {
                            self.gesture_bindings.navigation_forward.clone()
                        };
                        if let Some(binding) = binding {
                            self.gesture_chord(&binding)?
                        }
                    }
                    self.swipe_triggered = true;
                }
                if phase == PHASE_ENDED {
                    self.swipe_triggered = false;
                }
                Ok(())
            }
            4 => {
                if let Some(binding) = self.gesture_bindings.smart_magnify.clone() {
                    self.gesture_chord(&binding)?
                }
                Ok(())
            }
            8 => {
                if phase == PHASE_MAY_BEGIN || phase == PHASE_BEGAN {
                    self.swipe_triggered = false;
                }
                if phase == PHASE_CANCELLED {
                    self.swipe_triggered = false;
                    return Ok(());
                }
                if !self.swipe_triggered && value.abs() >= 1.0 {
                    let binding = if value > 0.0 {
                        self.gesture_bindings.spread.clone()
                    } else {
                        self.gesture_bindings.pinch_in.clone()
                    };
                    if let Some(binding) = binding {
                        self.gesture_chord(&binding)?
                    }
                    self.swipe_triggered = true;
                }
                if phase == PHASE_ENDED {
                    self.swipe_triggered = false;
                }
                Ok(())
            }
            3 | 5 | 6 | 0 => Ok(()),
            _ => Ok(()),
        }
    }
    fn wheel(&mut self, dx: f64, dy: f64) -> Result<()> {
        let mut events = Vec::new();
        let x = dx.round() as i32;
        let y = (-dy).round() as i32;
        if x != 0 {
            events.push(LinuxEvent::new(
                EventType::RELATIVE.0,
                RelativeAxisCode::REL_HWHEEL.0,
                x,
            ));
        }
        if y != 0 {
            events.push(LinuxEvent::new(
                EventType::RELATIVE.0,
                RelativeAxisCode::REL_WHEEL.0,
                y,
            ));
        }
        if !events.is_empty() {
            self.emit(&events)?
        }
        Ok(())
    }
}

fn gesture_key_code(key: GestureKey) -> KeyCode {
    match key {
        GestureKey::LeftCtrl => KeyCode::KEY_LEFTCTRL,
        GestureKey::LeftShift => KeyCode::KEY_LEFTSHIFT,
        GestureKey::LeftAlt => KeyCode::KEY_LEFTALT,
        GestureKey::LeftMeta => KeyCode::KEY_LEFTMETA,
        GestureKey::Left => KeyCode::KEY_LEFT,
        GestureKey::Right => KeyCode::KEY_RIGHT,
        GestureKey::Tab => KeyCode::KEY_TAB,
        GestureKey::Space => KeyCode::KEY_SPACE,
        GestureKey::A => KeyCode::KEY_A,
        GestureKey::D => KeyCode::KEY_D,
        GestureKey::S => KeyCode::KEY_S,
        GestureKey::Equal => KeyCode::KEY_EQUAL,
    }
}

impl InputSink for UinputSink {
    fn activate(
        &mut self,
        width: f64,
        height: f64,
        edge: DisplayEdge,
        normalized_position: f64,
    ) -> Result<()> {
        let position = normalized_position.clamp(0.0, 1.0);
        let (x, y) = match edge {
            DisplayEdge::Left => (1, (height * position).round() as i32),
            DisplayEdge::Right => (
                (width - 2.0).max(1.0) as i32,
                (height * position).round() as i32,
            ),
            DisplayEdge::Top => ((width * position).round() as i32, 1),
            DisplayEdge::Bottom => (
                (width * position).round() as i32,
                (height - 2.0).max(1.0) as i32,
            ),
        };
        self.emit(&[
            LinuxEvent::new(EventType::RELATIVE.0, RelativeAxisCode::REL_X.0, -32_767),
            LinuxEvent::new(EventType::RELATIVE.0, RelativeAxisCode::REL_Y.0, -32_767),
            LinuxEvent::new(EventType::RELATIVE.0, RelativeAxisCode::REL_X.0, x),
            LinuxEvent::new(EventType::RELATIVE.0, RelativeAxisCode::REL_Y.0, y),
        ])
    }

    fn inject(&mut self, event: &InputEvent) -> Result<()> {
        match event {
            InputEvent::PointerMove { dx, dy, .. } => self.emit(&[
                LinuxEvent::new(
                    EventType::RELATIVE.0,
                    RelativeAxisCode::REL_X.0,
                    dx.round() as i32,
                ),
                LinuxEvent::new(
                    EventType::RELATIVE.0,
                    RelativeAxisCode::REL_Y.0,
                    dy.round() as i32,
                ),
            ]),
            InputEvent::MouseButton { button, down, .. } => self.key(
                match button {
                    0 => KeyCode::BTN_LEFT,
                    1 => KeyCode::BTN_RIGHT,
                    2 => KeyCode::BTN_MIDDLE,
                    _ => KeyCode::BTN_SIDE,
                },
                *down,
            ),
            InputEvent::Scroll { dx, dy, .. } => self.wheel(*dx, *dy),
            InputEvent::Key { usage, down, .. } => {
                if let Some(key) = hid_to_linux(*usage) {
                    self.key(key, *down)
                } else {
                    Ok(())
                }
            }
            InputEvent::Modifiers(mask) => self.update_modifiers(*mask),
            InputEvent::Gesture {
                kind,
                phase,
                dx,
                dy,
                value,
                ..
            } => self.gesture(*kind, *phase, *dx, *dy, *value),
        }
    }
    fn release_all(&mut self) -> Result<()> {
        let held: Vec<_> = self.held.iter().copied().collect();
        for key in held {
            self.key(key, false)?
        }
        self.modifiers = 0;
        Ok(())
    }
}

impl Drop for UinputSink {
    fn drop(&mut self) {
        let _ = self.release_all();
    }
}

fn hid_to_linux(usage: u16) -> Option<KeyCode> {
    let code = match usage {
        0x04..=0x1d => [
            30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47,
            17, 45, 21, 44,
        ][(usage - 4) as usize],
        0x1e..=0x26 => [2, 3, 4, 5, 6, 7, 8, 9, 10][(usage - 0x1e) as usize],
        0x27 => 11,
        0x28 => 28,
        0x29 => 1,
        0x2a => 14,
        0x2b => 15,
        0x2c => 57,
        0x2d => 12,
        0x2e => 13,
        0x2f => 26,
        0x30 => 27,
        0x31 => 43,
        0x33 => 39,
        0x34 => 40,
        0x35 => 41,
        0x36 => 51,
        0x37 => 52,
        0x38 => 53,
        0x39 => 58,
        0x3a..=0x45 => 59 + (usage - 0x3a),
        0x49 => 110,
        0x4a => 102,
        0x4b => 104,
        0x4c => 111,
        0x4d => 107,
        0x4e => 109,
        0x4f => 106,
        0x50 => 105,
        0x51 => 108,
        0x52 => 103,
        0x53 => 69,
        0x54 => 98,
        0x55 => 55,
        0x56 => 74,
        0x57 => 78,
        0x58 => 96,
        0x59..=0x61 => [79, 80, 81, 75, 76, 77, 71, 72, 73][(usage - 0x59) as usize],
        0x62 => 82,
        0x63 => 83,
        0xe0 => 29,
        0xe1 => 42,
        0xe2 => 56,
        0xe3 => 125,
        0xe4 => 97,
        0xe5 => 54,
        0xe6 => 100,
        0xe7 => 126,
        _ => return None,
    };
    Some(KeyCode::new(code))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn maps_hid_keys() {
        assert_eq!(hid_to_linux(0x04), Some(KeyCode::KEY_A));
        assert_eq!(hid_to_linux(0xe3), Some(KeyCode::KEY_LEFTMETA));
    }
}
