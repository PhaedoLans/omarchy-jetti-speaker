# Publishing checklist

Nothing here is published yet. This is what to use and what to check first.

## Repository description

The one-liner that appears under the repo name, in search results, and on your
profile:

> Use all detectable speakers you connect to your computer at once, and
> harmonize them with AI.

## Suggested repo name

`omarchy-jetti-speaker` — the convention for Omarchy plugins is to prefix the
repo with `omarchy-`. The repo name does not have to match the plugin id
(`jetti.speaker`), and the install command uses the git URL, not the name.

## Before making it public

- [ ] **Re-check the test fixtures.** `tests/fixtures/data/*.json` are captured
      from live hardware. They were scrubbed once — a real Bluetooth MAC address
      and machine-specific sysfs paths — but they are easy to regenerate
      carelessly. Confirm no real MAC:
      `grep -rIoE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' . | grep -v AA:BB`
- [ ] **Decide the public attribution.** `manifest.json` `author` and the
      LICENSE copyright line currently read `jetti`. MIT requires anyone
      redistributing to preserve that copyright notice, so it is the attribution
      that actually travels.
- [ ] **Decide the commit email.** Commits currently carry a real address, which
      is permanently visible and scrapeable once public. GitHub's
      `<user>@users.noreply.github.com` avoids that, but switching means
      rewriting existing commits.
- [ ] **Set `homepage` and `repository`** in `manifest.json` once the URL exists.
- [ ] **Consider how much testing it has had.** Written in a day on one machine,
      confirmed working on a second. The measurement approach should adapt to
      different hardware, but several things met here were specific to one
      sound card. A few invited testers before a public repo is the cheaper
      order.

## How people install it

```bash
omarchy plugin add https://github.com/<user>/omarchy-jetti-speaker.git --enable
```

That clones, validates against the manifest schema, refuses symlinks, and
enables it. Verified working from a bare local repo; see also `install.sh` for
the offline path.
