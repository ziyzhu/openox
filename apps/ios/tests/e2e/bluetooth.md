# Bluetooth

The built-in `ios:bluetooth` service uses foreground Core Bluetooth central
sessions. Each chat and canvas owns its connections, opaque attribute handles,
and notification cursor. Deselecting a chat, stopping it, detaching Bluetooth,
closing a canvas, backgrounding Ox, or 120 seconds without a Bluetooth action
closes the session. Status does not refresh the idle timer.

## Simulator verification

Start the repository server for the selected numbered simulator and verify
`/health`, then build/install/launch with `sim` and matching repository/debug
ports. Add Bluetooth from the Services picker. Inspect the ten action contracts
through `ox vm` and invoke `status`, `events`, and invalid input cases. Confirm
that unavailable radio operations return an error without hanging or crashing.
The simulator does not verify physical discovery, pairing, or GATT exchanges.

## Physical device verification

Use an available iPhone running iOS 26 or later and a controllable BLE peripheral
with a standard Battery Service plus documented custom read, write, and notify
characteristics. Preserve evidence outside the repository.

1. Check status before first use: it must not request permission. Scan, reject
   permission, and verify an actionable unauthorized result. Enable permission
   in Settings, turn Bluetooth off/on, then verify scanning recovers.
2. Scan, select the peripheral, connect, and inspect. Verify service filters,
   duplicate characteristic UUIDs, descriptor handles, and per-mode write limits.
   Read Battery Level and Device Information; compare raw bytes with the device.
3. Write a documented reversible command. Deny approval and verify no device
   effect. Approve it, then independently read back or observe the intended
   effect. Verify response writes report acknowledged and response-free writes
   report queued. Oversized writes must fail without splitting or retrying.
4. Subscribe, generate updates, and read successive event cursors. Produce more
   than 256 updates and check `dropped`. Unsubscribe and verify updates stop.
5. Disconnect during discovery/read/write, omit a response until timeout, cancel
   a scan, change the GATT service tree, and background the app during a request.
   Pending work must settle; expired handles must fail; scanning must recover.
6. Connect two peripherals. Disconnect the idle one while reading the other;
   the active request must remain valid. Verify a second chat/canvas cannot use
   the first caller's handles and closing one caller does not close the other.
7. Wait beyond the idle timeout, then reconnect and inspect. Verify notification
   cursors report cleared events as dropped instead of silently reusing sequences.

## Protocol learning

Use advertisement identifiers, GATT UUIDs, and documented Device Information to
identify a candidate protocol. Names and UUIDs are evidence, not authentication.
Match Bluetooth SIG profiles first, then consult the manufacturer's protocol or
source. Preserve unknown bytes instead of inventing a decoding or write command.

Verify each command against a device response or independently observed effect.
When the user asks to retain a learned workflow, create an ordinary Ox skill
attached to `ios:bluetooth`. Record model/firmware applicability, source URLs,
UUID matching rules, byte encoding, response decoding, timing requirements, and
verified commands. Rediscover opaque handles on every new session; never save
them as device identities. Keep credentials and reusable authentication secrets
out of skill text, tool arguments, and diagnostics.

This version provides transport primitives and limited standard value decoding.
It does not implement arbitrary Classic profiles, proprietary authentication,
automatic protocol inference, persistent pairing records, background monitoring,
or a local engine for timing-sensitive multi-packet exchanges.

Apple references:

- https://developer.apple.com/documentation/corebluetooth
- https://developer.apple.com/documentation/corebluetooth/cbperipheral
- https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription
