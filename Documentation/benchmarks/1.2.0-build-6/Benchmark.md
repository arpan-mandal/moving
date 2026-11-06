# Moving 1.2.0 performance on Apple M5

Measured November 5, 2026. The installed Moving 1.2.0 build 6 ran on a 10-core Apple M5 Mac with 16 GiB unified memory, macOS 27.2 (26B123), and one built-in Retina display in 3420 × 2224 mode. The Mac was on AC power with Low Power Mode off. Moving used Balanced, Automatic quality, 30 fps and Crop, with its Displays view open in both samples. Other apps were left running.

The assigned source was a 15.23-second 3840 × 2160 video at 60 fps. The playback cache contained a 1920 × 1080 H.264 copy at 30 fps. This benchmark measures steady playback after the copy was available.

| State and process | Duration | Mean CPU | Median physical footprint | Highest sampled footprint |
| --- | ---: | ---: | ---: | ---: |
| Playing, Moving | 45.17 s | 0.047% | 62.8 MiB | 63.7 MiB |
| Playing, Moving's VideoToolbox decoder | 10.04 s | 0.051% | 66.0 MiB | 66.5 MiB |
| Display covered and playback paused, Moving | 30.11 s | 0.0012% | 58.6 MiB | 58.6 MiB |

The installed app reported Playing before and after the active sample. Window coverage was checked approximately every two seconds during the active run. In the covered baseline, the app reported Paused · display covered while a maximized window covered the display. That baseline preceded the active run and does not measure memory retained after a new pause. The decoder was identified through the Moving process's launchd domain, and its shorter sample overlapped the end of the active run.

The sampler read macOS per-process cumulative user and system CPU time and physical memory footprint approximately once per second. Mean CPU divides the change in CPU time by elapsed time, so 100% is one fully used core. The memory peak is the highest one-second sample. The two processes are reported separately because system memory can include shared allocations. These results do not measure GPU or media-engine utilization, WindowServer's incremental work, frame drops, or whole-system energy. [Apple's explanation of the physical footprint metric](https://developer.apple.com/videos/play/wwdc2022/10106/)

## Preparing a playback copy

Three trials per policy used the same original source and Moving's release-optimized proxy code. Each trial started with an empty app proxy directory. The playback cache already present in the installed app was not used. All trials ran on AC power. The second row selects the Balanced battery limits in the benchmark code. Elapsed time starts at the request to create a playback copy and ends when the file is ready. It excludes opening the picker, importing, and showing the first frame.

| Policy | Output | Median conversion | Trial range | Output size |
| --- | --- | ---: | ---: | ---: |
| Balanced on AC | 1920 × 1080 at 30 fps | 1.81 s | 1.81–1.91 s | 16.55 MiB |
| Balanced with battery limits | 1280 × 720 at 24 fps | 1.48 s | 1.47–1.48 s | 10.46 MiB |

Subsequent cache lookups took 0.14–0.61 ms across the six trials. This is the lookup alone, before AVFoundation starts playback.

Battery drain was not measured. The Mac remained plugged in, and the available hardware power sampler requires admin access. These results represent one machine and one clip and do not establish performance on Intel, other displays, other codecs, or earlier Moving versions.

The adjacent CSVs, JSON and sampler sources contain the raw data and measurement code. The installed executable SHA-256 was ef642d4f54952f88b78227172876d10321dc203e95fc71ac93fee8b5f6e3fe50.
