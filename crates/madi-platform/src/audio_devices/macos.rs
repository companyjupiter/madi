//! Core Audio discovery matching AudioDevices.swift's order and filtering.
use super::{InputDevice, InputDevices};
use objc2_core_audio::*;
use objc2_core_audio_types::{AudioBuffer, AudioBufferList};
use objc2_core_foundation::{CFRetained, CFString};
use std::mem::{align_of, offset_of, size_of};
use std::ptr::{NonNull, null, null_mut};

pub(super) fn snapshot() -> InputDevices {
    let ids = property_bytes(
        kAudioObjectSystemObject as u32,
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
    )
    .unwrap_or_default();
    let devices = ids
        .as_chunks::<4>()
        .0
        .iter()
        .map(|id| u32::from_ne_bytes(*id))
        .filter(|&id| {
            property_bytes(
                id,
                kAudioDevicePropertyStreamConfiguration,
                kAudioObjectPropertyScopeInput,
            )
            .is_some_and(|data| has_input_channels(&data))
        })
        .filter_map(|id| {
            let name = device_name(id).unwrap_or_else(|| format!("Device {id}"));
            (!name.starts_with("CADefaultDeviceAggregate")).then_some(InputDevice {
                id: format!("coreaudio:{id}"),
                name,
            })
        })
        .collect();
    let default_input_id = property_bytes(
        kAudioObjectSystemObject as u32,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
    )
    .and_then(|data| data.try_into().ok())
    .map(|id| format!("coreaudio:{}", u32::from_ne_bytes(id)));
    InputDevices {
        supported: true,
        devices,
        default_input_id,
    }
}

fn address(selector: u32, scope: u32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress {
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain,
    }
}

fn property_bytes(id: u32, selector: u32, scope: u32) -> Option<Vec<u8>> {
    let mut address = address(selector, scope);
    let mut size = 0;
    // SAFETY: address and size are live, correctly aligned values. These
    // properties have no qualifier and discovery does not open an audio stream.
    let status = unsafe {
        AudioObjectGetPropertyDataSize(
            id,
            NonNull::from(&mut address),
            0,
            null(),
            NonNull::from(&mut size),
        )
    };
    // Bound driver-reported allocation. Empty configuration means no input.
    if status != 0 || size == 0 || size > 1024 * 1024 {
        return None;
    }
    // AudioBufferList includes pointers, so Vec<u8>'s alignment is insufficient.
    const { assert!(align_of::<AudioBufferList>() <= align_of::<u64>()) };
    let mut words = vec![0_u64; (size as usize).div_ceil(size_of::<u64>())];
    let capacity = size;
    // SAFETY: the nonempty zeroed allocation has capacity >= size and alignment
    // sufficient for both AudioBufferList and device IDs. HAL receives the actual
    // byte capacity. A device disappearing between calls returns an error.
    let status = unsafe {
        AudioObjectGetPropertyData(
            id,
            NonNull::from(&mut address),
            0,
            null(),
            NonNull::from(&mut size),
            NonNull::new(words.as_mut_ptr()).unwrap().cast(),
        )
    };
    if status != 0 || size > capacity {
        return None;
    }
    // SAFETY: bytes are initialized and the checked size is within words. Copy
    // out so downstream parsers need no unsafe casts or borrowed HAL pointers.
    Some(unsafe { std::slice::from_raw_parts(words.as_ptr().cast::<u8>(), size as usize) }.to_vec())
}

fn has_input_channels(data: &[u8]) -> bool {
    let Some(count) = data
        .get(..4)
        .map(|v| u32::from_ne_bytes(v.try_into().unwrap()) as usize)
    else {
        return false;
    };
    let offset = offset_of!(AudioBufferList, mBuffers);
    let stride = size_of::<AudioBuffer>();
    if count > data.len().saturating_sub(offset) / stride {
        return false;
    }
    (0..count).any(|index| {
        let start = offset + index * stride + offset_of!(AudioBuffer, mNumberChannels);
        u32::from_ne_bytes(data[start..start + 4].try_into().unwrap()) > 0
    })
}

fn device_name(id: u32) -> Option<String> {
    let mut address = address(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal);
    let mut value: *mut CFString = null_mut();
    let mut size = size_of::<*mut CFString>() as u32;
    // SAFETY: the property is a CFStringRef and value is its pointer-sized output
    // slot. AudioHardwareBase.h explicitly transfers ownership to the caller.
    let status = unsafe {
        AudioObjectGetPropertyData(
            id,
            NonNull::from(&mut address),
            0,
            null(),
            NonNull::from(&mut size),
            NonNull::from(&mut value).cast(),
        )
    };
    if status != 0 || size != size_of::<*mut CFString>() as u32 {
        return None;
    }
    // SAFETY: on success HAL returned a retained CFString (not a borrowed one).
    // CFRetained releases it once after copying the display name to Rust.
    let name = unsafe { CFRetained::from_raw(NonNull::new(value)?) };
    Some(name.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_variable_length_buffer_list_before_reading_channels() {
        let offset = offset_of!(AudioBufferList, mBuffers);
        let stride = size_of::<AudioBuffer>();
        let mut data = vec![0; offset + 2 * stride];
        data[..4].copy_from_slice(&2_u32.to_ne_bytes());
        assert!(!has_input_channels(&data));
        data[offset + stride..offset + stride + 4].copy_from_slice(&2_u32.to_ne_bytes());
        assert!(has_input_channels(&data));
        assert!(!has_input_channels(&data[..data.len() - 1]));
        data[..4].copy_from_slice(&u32::MAX.to_ne_bytes());
        assert!(!has_input_channels(&data));
        assert!(!has_input_channels(&[]));
        assert!(!has_input_channels(&[0, 0, 0]));
    }
}
