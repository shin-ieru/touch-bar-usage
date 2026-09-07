---
name: Touch Bar compatibility
about: The badge or dashboard doesn't render correctly
labels: touch-bar
---

The Touch Bar integration uses undocumented macOS APIs, so behaviour varies by
macOS version and Touch Bar setting. These details are what make a report useful.

**What you see**
- [ ] No badge in the Control Strip
- [ ] Badge appears but tapping does nothing
- [ ] Dashboard opens but renders incorrectly
- [ ] Native Touch Bar not restored after Close
- [ ] Other:

**Touch Bar setting**
System Settings → Keyboard → Touch Bar Settings
- Touch Bar shows:
- Show Control Strip: On / Off

> The badge requires **App Controls + Show Control Strip**. In other modes macOS
> does not render third-party Control Strip items — that is expected, not a bug.

**Does the menu-bar fallback work?**
Menu bar → Show Usage on Touch Bar: yes / no

**Environment**
- Mac model and year:
- Architecture: Apple Silicon / Intel
- macOS version:
- App version:

**Diagnostics output**

```
paste here
```
