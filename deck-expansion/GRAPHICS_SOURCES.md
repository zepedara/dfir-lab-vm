# FOR508.2 Deck — Graphics for the 14 graphic-less slides (sources, licenses, attribution)

All images are downloaded into `graphics\` and are **freely licensed for reuse** (no SANS courseware, no all-rights-reserved vendor images). For 10 slides there's a ready-to-drop image; for 4 dense technical slides a clean, license-safe **make-your-own diagram spec** is provided instead (free Windows-UI screenshots / vendor diagrams don't exist under reusable licenses).

## Drop-in images (in `graphics\`)

| Slide | File | Source (direct URL) | License | Attribution required? |
|---|---|---|---|---|
| 1 — Title | `slide01_title_cybersecurity_CC0.png` | upload.wikimedia.org/wikipedia/commons/4/46/Cybersecurity.png | **CC0 1.0** (public domain) | No |
| 2 — Learning Objectives | `slide02_objectives_checklist_Unsplash.jpg` | images.unsplash.com/photo-1768055104910-8c8d213835fb | **Unsplash License** | No (courtesy: "Photo by Jakub Żerdzicki on Unsplash") |
| 3 — Evidence of Execution (divider) | `slide03_evidence-of-execution_terminal_Unsplash.jpg` | images.unsplash.com/photo-1629654297299-c8506221ca97 | **Unsplash License** | No (courtesy: "Photo by Gabriel Heinzer on Unsplash") |
| 6 — Prefetch theory (memory) | `slide06_prefetch_RAM_DDR4_CCBYSA.jpg` | upload.wikimedia.org/wikipedia/commons/6/6c/RAM_Module_%28SDRAM-DDR4%29.jpg | **CC BY-SA 4.0** | **YES** |
| 20 — Event Log Analysis (divider) | `slide20_eventlog_serverrack_Pexels.jpeg` | images.pexels.com/photos/17489157/pexels-photo-17489157.jpeg | **Pexels License** | No |
| 28 — Lateral Movement (divider) | `slide28_lateralmovement_network_CCBYSA.png` | upload.wikimedia.org/wikipedia/commons/f/ff/Network_Visualization.png | **CC BY-SA 4.0** | **YES** |
| 34 — Other Vectors & Tools | `slide34_othervectors_datacenter_CCBY.jpg` | upload.wikimedia.org/wikipedia/commons/b/b3/Datacenter_Server_Racks_%2822370909788%29.jpg | **CC BY 2.0** | **YES** |
| 35 — Command Line (divider) | `slide35_commandline_bashprompt_CC0.gif` | upload.wikimedia.org/wikipedia/commons/1/1d/Animated_GNU_Bash_Unix_Shell_Prompt.gif | **CC0 1.0** | No |
| 38 — Command-Line Auditing | `slide38_cmdaudit_dircommand_PD.png` | upload.wikimedia.org/wikipedia/commons/1/10/Dir_command_in_Windows_Command_Prompt.png | **Public Domain** | No |
| 40 — PowerShell (title glyph) | `slide40_powershell_icon_MIT.svg` | upload.wikimedia.org/wikipedia/commons/a/a1/Powershell_128.svg | **MIT** | Yes (courtesy: Microsoft) |

### Attribution strings to place on/under the attribution-required images
- **Slide 6:** *"RAM Module (SDRAM-DDR4).jpg by ElooKoN, CC BY-SA 4.0, via Wikimedia Commons."* (share-alike: if you recolor/adapt it, license the adaptation compatibly.)
- **Slide 28:** *"'Network Visualization' by Martin Grandjean, via Wikimedia Commons, CC BY-SA 4.0 (creativecommons.org/licenses/by-sa/4.0/)."* (share-alike applies to adaptations.)
- **Slide 34:** *"'Datacenter Server Racks' by Carl Lender, via Wikimedia Commons, CC BY 2.0."*
- **Slide 40:** PowerShell icon © Microsoft, MIT License (from the official PowerShell repo).

> A small credit line in the slide footer (or one final "Image Credits" slide) satisfies all four. The CC0 / Unsplash / Pexels / Public-Domain images (slides 1, 2, 3, 20, 35, 38) need nothing.
>
> **Note on slide 34:** the file is full-resolution (6000×4000, ~11 MB). PowerPoint recompresses images on save, but you can also right-click → *Compress Pictures* to shrink the deck.

---

## Make-your-own diagram specs (slides 36, 37, 39, 41)

No reusable real image fits these — Windows-UI screenshots are copyright-rejected on Wikimedia and vendor (Red Canary/Eideon/etc.) diagrams are all-rights-reserved. A simple original boxes-and-arrows diagram is both clearer and license-clean. Build them in PowerPoint SmartArt/shapes:

### Slide 36 — Event Log Attacks & Clearing  (detection vs. evasion)
- Center box **"Log Clearing"** → two arrows up to **`1102` (Security — "audit log cleared", names the account)** and **`104` (System — other logs)**; label these **T1070.001**.
- Bottom banner **"Advanced selective deletion — T1562.002"** over three boxes: **Mimikatz `event::drop` → patches the service (suppresses 1102)** · **Invoke-Phant0m → kills logging threads (service still "Running")** · **DanderSpritz `eventlogedit` → unlinks records (gaps, no clear event)**.
- Right box: **Mitigation → Windows Event Forwarding (off-box copy) + alert on 1100**.

### Slide 37 — Evidence of Malware Execution  (artifact pivot map)
- Center node **"Malware ran (binary may be deleted)"** → four arrows to: **Application log `1000` Error / `1002` Hang** · **WER `1001` → `.wer` = full path, modules, *SHA1*** · **Defender `…Defender/Operational` `1116` detected / `1117` action** · **MPLog (`MPLog-*.log`, plaintext) → execution + file-access timeline, hashes, injection**.
- Star the two **SHA1-bearing** sources (WER, MPLog): "recover the hash even with no binary."

### Slide 39 — WMI Attacks & Persistence  (the three-object model)
- Three linked boxes L→R: **`__EventFilter` (trigger)** → **`__FilterToConsumerBinding` (the link — highlight color)** → **`EventConsumer` (payload: CommandLine/ActiveScript)**.
- Wrap all three in a container **`root\subscription` (WMI repo — OBJECTS.DATA, not a file on disk)**.
- Detection callouts: **native `5861` (consumer/binding created) + noisy `5858`** and **Sysmon `19 / 20 / 21`**. Tag **T1546.003**.

### Slide 41 — Sysmon  (EID reference card)
- 2-column table titled **"Sysmon — config-driven, not installed by default"**:
  `1` Process Creation (+hashes, cmdline) · `3` Network Connection · `7` Image Load · `8` CreateRemoteThread · `10` ProcessAccess · `11` FileCreate · `13` Registry · `19/20/21` WMI Filter/Consumer/Binding · `22` DnsQuery · `25` ProcessTampering · `26` FileDelete.
- Footer: **"Config = SwiftOnSecurity/sysmon-config or Olaf Hartong/sysmon-modular."** (both MIT/permissive; cite the repo on-slide rather than embedding an image).
