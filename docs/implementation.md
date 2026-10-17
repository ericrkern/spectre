# Quis Pulsat Implementation Plan

This plan builds the investigation app described in [README.md](README.md) and [architecture.md](architecture.md). Each phase leaves a session the investigator can run on a phone. Later phases add leads. They do not replace the session, the clock, or the rule that each detector stays independent.

A hit is a lead: time, sensor, feature, magnitude, and a short sample window. The app never collapses coincident hits into one supernatural score.

Out of the investigation loop for this plan: RF EMF, lux, room temperature, infrasound, raw TrueDepth infrared, continuous NFC or Wi-Fi scans, and Ultra Wideband ranging. Those signals are unavailable or not comparable to the phone’s public sensors. See the architecture doc for why.

## Phase 1 — App shell and session clock ✅

Create the iOS app and the object everything else hangs on: a foreground session with one clock.

- ✅ SwiftUI app target, current iPhone OS, portrait, no background modes.
- ✅ The investigator names a place and captures the current readings. The clock runs while Quis Pulsat is open. Sensors stay on screen the whole time.
- ✅ One monotonic clock. A capture stores elapsed time on that clock and the wall-clock time.
- ✅ Permission copy for Motion, Location When In Use, Microphone, Camera, and Bluetooth, written as “recording this sensor for an investigation session.” Motion, the magnetometer, and the barometer start without a prompt. The other sensors ask only when that widget is tapped.
- ✅ Every sensor is always visible. Live, unavailable, denied, and not-yet-asked are labeled on the widget. Denied says the lead is omitted. A denied widget opens Settings.

✅ Done when a session starts and stops on a device, the clock runs, and the screen reports motion hardware honestly before any detector exists. Verified on the iPhone 17 Pro simulator. The running screen is now the live dashboard, and capture saves a named snapshot instead of stopping the sensors.

## Phase 2 — Motion pipeline and the first leads

Open Core Motion and ship the first detectors against a short baseline.

- ✅ Acquire `CMDeviceMotion` (user acceleration and the calibrated magnetic field) and `CMAltimeter` relative pressure. Device motion is the source, and both stream while the app is in the foreground.
- ✅ The raw magnetometer vector is sampled alongside device motion and kept for the unfused field.
- ✅ Baseline the first few seconds after the phone has been still. Pressure also keeps a slow rolling baseline so weather and HVAC drift do not look like a step.
- ✅ Magnetic-disturbance detector: field magnitude, vector jump, and calibrated accuracy falling to low or unreliable. A raw-field jump is its own lead when the calibrated accuracy is poor.
- ✅ Pressure-change detector: a short-term step after the slow trend is removed.
- ✅ Unattended-motion detector: user acceleration and rotation only while the phone has been still. Samples are ignored while the pedometer reports new steps.
- ✅ Live gauges for field strength, pressure, and motion. Each gauge shows the latest sample and does not score a lead. The same treatment covers the other sensors: a needle for steps, sound level, brightness, and depth; a compass rose for heading; a radar dial for nearby Bluetooth devices; a map for location.

✅ Done when a magnet brought near a resting phone, a door or HVAC pressure step, and a bump of a still phone each produce their own hit, and walking with the phone does not. Covered by the detector tests. A magnetic lead and a pressure lead at the same time stay two hits.

## Phase 3 — Session log and replay

Persist hits and make them reviewable after the session.

- ✅ Capture and save writes the place name, elapsed time, wall time, and every sensor’s status and displayed value. The list is stored on disk and is still there after the app is closed.
- ✅ Each hit is saved on its own when it crosses a threshold: place, time, sensor snapshot, feature, magnitude, the threshold it crossed, and the sample window. A haptic and a Detected banner mark the new hit. The magnetometer ticks with its reading instead of a beep on the hit.
- ✅ The lead list is that saved timeline. Coincident hits from different detectors stay separate rows.
- ✅ Opening a hit in the list shows the sample window that triggered it.

✅ Done when a session survives leaving the screen, and the investigator can open a past hit and see the samples that caused it. Detections are written to disk as they happen. A saved hit shows its magnitude, its threshold, and the window. A sound hit plays its clip from the lead row.

## Phase 4 — Sound

Add the microphone as its own lead, gated on a quiet-room baseline.

- ✅ The microphone streams a level in dB after the widget is tapped and permission is granted. The dial is labeled in decibels, not infrasound. A denial shows the lead as omitted.
- ✅ Capture prefers 48 kHz and reduces each window to RMS level, a transient peak, and a narrow-tone share.
- ✅ Baseline the first five seconds after the microphone is on. A hit is a peak 10 dB above that floor, or a narrow tone held for 0.4 s and 8 dB above the floor.
- ✅ Each sound hit stores a short clip. The lead row has Play clip.

✅ Done when a clap or a sustained tone in an otherwise quiet room logs a sound hit with playable audio, and speech-band noise during the baseline does not immediately re-trigger. Covered by the sound detector tests. The level gauge still does not score a lead.

## Phase 5 — Heading cross-check

Add compass heading so magnetic hits and heading hits can share one physical explanation.

- ✅ Core Location heading runs in the foreground after the compass or location widget is tapped. When-in-use location only. The needle points at magnetic heading.
- ✅ Heading-instability detector: heading accuracy worsening, or yaw wander, only while the unattended-motion detector says the phone is still. Turning the phone clears the lock.
- ✅ A heading hit within two seconds of a magnetic hit stays two rows under Same moment, and each row keeps its own sample window.

✅ Done when turning the phone is not logged as a hit, and a magnet that pulls the compass logs heading instability only while the phone is still. Covered by the heading tests.

## Phase 6 — Brightness

Infer room brightness from the camera, since iOS has no public lux sensor.

- ✅ The back camera’s average luma is shown on a needle dial after camera permission. On a LiDAR phone the same permission uses the ARKit light estimate, so the camera is not opened twice. There is no photo library.
- ✅ Exposure time, ISO, and aperture are read with the luma. The camera widget shows them under the needle so the aim is visible when auto-exposure holds the luma steady. A LiDAR phone reports exposure duration from ARKit and leaves ISO and aperture blank.
- ✅ Brightness-shift detector against a five-second baseline. Luma, exposure, ISO, and aperture each stay their own hit. The hit stores the meter window, not a photo.

✅ Done when switching a room light, with the phone aimed at a stable surface, logs a brightness hit, and a phone without camera permission simply omits the lead. The shift is covered by the brightness tests. A denied camera still shows the lead as omitted.

## Phase 7 — Empty-space depth ✅

On LiDAR phones, watch for depth changes in space the mesh marked empty.

- ✅ ARKit scene depth runs only when the phone supports it, using the same camera permission as brightness. The dial shows the center depth in meters. A phone without LiDAR shows the sensor as unavailable and the other widgets keep running.
- ✅ Baseline the empty regions, then flag depth changes there. Store depth and confidence for the hit window, not a person-identification result.

✅ Done when a LiDAR phone logs a depth hit as something enters a region that was empty at baseline, and a non-Pro phone runs the rest of the session unchanged. The non-Pro case is how the dashboard behaves. The depth hit is covered by the depth detector tests.

## Phase 8 — Nearby radios and place ✅

Log Bluetooth appearances, and store a location so a session can be placed on a map later. Neither one blocks the earlier detectors.

- ✅ A Bluetooth scan counts nearby peripherals and draws one radar dot per device, up to twelve. It starts when the widget is tapped. The count is saved with a capture. It does not guess what the device is.
- ✅ Scan hits for a new advertisement or a sharp RSSI change, and store the advertisement data and RSSI.
- ✅ When-in-use location shows latitude and longitude on a map. A capture saves that reading with the other sensors. GPS is a place marker, not an anomaly detector.
- ✅ Ultra Wideband and NFC are meters, not leads. UWB shows no peer until another device joins a session, and NFC reads a tag the investigator holds up.

✅ Done when a watch or tracker entering the room appears on the timeline as a radio lead, and a saved session shows where it was recorded when location was allowed. The radio lead is covered by the radio detector tests. A saved capture includes the map reading when location was allowed.

## After each phase

Run the session on a device, not only the simulator. The simulator cannot stand in for the magnetometer, barometer, or LiDAR. Confirm three things before starting the next phase:

- A denied permission omits that lead and the screen says why.
- A phone missing the hardware omits that lead and the other detectors still run.
- Two leads at the same moment stay two hits.
