# BRIR Convolver

A native macOS app (Apple silicon, macOS 14.4+) that applies a true-stereo BRIR to **all system audio**,
built so it can sit in front of GraphWorks EQ.

## Signal flow

```
Every app ──▶ [Core Audio process tap: originals muted] ──▶ BRIR Convolver
                                                            (64-bit FFT convolution)
                                                                   │
                                                                   ▼
                                    GraphWorks EQ virtual device (the macOS output)
                                                                   │
                                                     GraphWorks EQ app (headphone EQ)
                                                                   │
                                                                   ▼
                                                         Your DAC / headphones
```

The BRIR (virtual speakers + room) comes first and the headphone EQ comes last, which is the correct
order: the EQ corrects the headphone itself, so it should apply to whatever reaches the headphone.

There's no extra driver. The app uses Apple's process-tap API to capture the system mix and mute the
originals, so you don't get a dry signal plus a convolved one at the same time. It **never taps itself or
GraphWorks EQ**: any audio process whose bundle ID or executable path contains `graphworks` or `gweq`
is excluded automatically. If GraphWorks EQ were tapped, its own output would loop back into the chain.

## Setup

1. Double-click `Build and Test.command`. It builds the app, runs the self-test and installs it to
   `/Applications`. You need Xcode or the Command Line Tools (`xcode-select --install`).
2. Leave **GraphWorks EQ** set as the macOS sound output, with GraphWorks EQ outputting to your DAC as usual.
3. Open **BRIR Convolver**, drop your 4-channel true-stereo BRIR WAV onto the window (for example one
   exported from ASH Toolset), and turn on *Enable system-wide convolution*.
4. The first time, macOS asks for **System Audio Recording** permission. Allow it. If you dismissed the
   prompt, go to System Settings → Privacy & Security → Screen & System Audio Recording →
   *System Audio Recording Only* and enable BRIR Convolver. Each rebuild changes the ad-hoc signature,
   so you may need to allow it again after rebuilding.
5. Keep *Output → System default output* to follow whatever macOS is set to (GraphWorks EQ), or pick
   a device explicitly.

The headphone icon in the menu bar has quick enable/bypass controls. Closing the window keeps the app
running.

![Main window](Screenshots/main-window.png)

The **Status** section shows live performance figures:
- **Added delay** is the latency this app adds: Core Audio capture→output (measured from HAL timestamps)
  plus the convolver partition. The output device's own reported latency is shown separately, because
  it applies with or without this app.
- **DSP** is the compute time per audio callback (average and recent peak) against the callback's deadline.
- **Load** is that average as a share of the deadline.

## BRIR analysis

Click **Analysis…** in the main window, or choose *BRIR Analysis…* from the menu-bar icon, to inspect
the loaded impulse response. Orange is the left speaker and blue the right. Solid lines are the
same-side ear and dashed lines the opposite ear. Hover any chart for exact values, and click a legend
entry to hide that path. The tiles across the top summarise reverb time (RT60), early decay time (EDT),
direct-to-reverberant ratio (DRR), clarity (C50) and the interaural level and time differences (ILD, ITD).

**Frequency response:** the EQ the BRIR applies on each speaker-to-ear path, with ¹⁄₄₈ to ⅓-octave smoothing.
An *Ear sum* mode shows the net colouration of centred content.

![Frequency response](Screenshots/frequency-response.png)

**Reverb decay:** Schroeder energy-decay curves for each path over the 1 ms peak envelope, plus RT60 per
octave band.

![Reverb decay](Screenshots/reverb-decay.png)

**Spectrogram:** time–frequency energy of all four paths on a shared dB scale.

![Spectrogram](Screenshots/spectrogram.png)

**Impulse:** the raw waveforms over the first 3–100 ms, showing the direct sound, the interaural delay and
level difference, and the first reflections.

![Impulse](Screenshots/impulse.png)

## Audio quality notes

- **The audio stream is never resampled by this app.** Convolution runs at whatever rate the output
  device (GraphWorks EQ's device) is running. If that rate isn't the BRIR's native rate, only the
  *impulse response* is resampled. That happens once, offline, with a 64-zero-crossing Kaiser-windowed
  sinc in double precision. The status line says "IR native rate" or "IR resampled from …".
- **64-bit DSP.** The WAV is decoded exactly to double. FFTs, spectral multiply-accumulate and the
  inverse transform are all double precision (Accelerate/vDSP). The self-test checks the output against
  a direct time-domain convolution, and the error should sit at the Float32 output floor (≈ −140 dB or better).
- **Bit-exact bypass.** In bypass the output is the input sample-for-sample, with the same latency as
  the wet path, so you can A/B without a timing shift. The self-test checks this bit for bit.
- **Linear by default.** The preamp is an exact scalar gain. The optional limiter is **off** by default.
  *Auto preamp* sets the gain so that no frequency, at either ear, is boosted above 0 dB, using
  max(|LL|+|RL|, |LR|+|RR|). Watch the clip counter if you raise the preamp by hand.
- **Latency** = partition size (256 samples = 5.3 ms at 48 kHz) plus the device IO buffer.
  Smaller partitions lower the latency and cost more CPU. The self-test prints CPU cost for each size.
- The render thread does no allocation, locking or Objective-C messaging.

## Channel order

For a 4-channel file the default order is **L→L, L→R, R→L, R→R**, the Equalizer APO / ASH-Toolset
convention: channels 1 and 4 are the strong same-side ear paths and channels 2 and 3 are the
opposite-side paths. If the stereo image sounds mirrored or odd, try the alternative order in the picker.

## Troubleshooting

- **Silence after enabling:** check the System Audio Recording permission (step 4) and that the
  *In* meter moves while something plays.
- **Clicks or dropouts:** raise the partition size, or turn off *Tap drift compensation* (that setting
  only applies when everything runs on GraphWorks EQ's clock).
- **GraphWorks EQ not listed under "Not tapping":** add its bundle ID under *Advanced → Also never tap*.
- Quitting the app removes the tap, and every other app is unmuted immediately.

## Rebuild / self-test only

```
./build.sh --test                  # self-test with a built-in synthetic BRIR
./build.sh --test path/to/brir.wav # or with your own
```
