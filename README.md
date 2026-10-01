# fdroid-tester

Test an app waiting in an [fdroiddata](https://gitlab.com/fdroid/fdroiddata)
merge request on your own Android phone, the way F-Droid's
[tester checklist](https://gitlab.com/fdroid/wiki/-/wikis/Internal/Reviewing-new-apps)
asks for, then post the filled-in report on the merge request.

New apps wait in fdroiddata until someone tests them on a real device. Most of
that test is the same every time: find the APK, check its permissions, watch
what it connects to, fill in the template. `fdroid-tester.sh` does those steps,
so you can spend your time actually using the app.

```sh
./fdroid-tester.sh https://gitlab.com/fdroid/fdroiddata/-/merge_requests/38458
```

## What it does

0. **Checks**: the tools, the phone, PCAPdroid and your `glab` login, before
   anything is downloaded. Anything missing comes with how to fix it.
1. **Merge request**: reads the merge request and its Code Quality report from
   gitlab.com. That gives the APK link, the permissions and the CI warnings. No
   login is needed for this.
2. **APK**: downloads the APK that fits your phone's CPU into the current
   folder. When the app has one APK per CPU type, it picks the right one.
3. **Inside the APK**:
   - special permissions reviewers question (`MANAGE_EXTERNAL_STORAGE`,
     `QUERY_ALL_PACKAGES`, …) and the runtime permissions
   - tracker code, using the [Exodus Privacy](https://reports.exodus-privacy.eu.org/) list
   - web addresses written in the code: online fonts, update checks,
     connectivity checks, trackers
   - WebView use, languages, and debuggable or plain-http flags
   - Google Play Services or Firebase code
4. **On the phone**: installs the app with `adb`, starts
   [PCAPdroid](https://f-droid.org/packages/com.emanuelef.remote_capture/) to
   record only this app's traffic, and opens the app. For the first seconds it
   watches for:
   - a crash, saving the crash log
   - a permission prompt on start, saving a screenshot
   - connections made on start

   Then you use the app, and it lists every server contacted while you did.
5. **Questions**: asks what only a person can tell. Does it work, do the
   features exist, is the icon its own, are there extra terms to accept, is
   there English, do links open inside the app?
6. **Report**: writes `report.md` in the wiki's report template, with the
   boxes already ticked from what it found, plus a details section with the
   evidence.
7. **Post**: lets you edit the report, then posts it as a comment on the same
   merge request with `glab`. It asks first, and only posts after a yes.

## Requirements

| Needed | For |
|---|---|
| bash 4.4+, curl, python3 (3.6+), unzip, sha256sum or shasum | everything |
| Android build-tools (`aapt2`) | reading the APK |
| `adb` (Android platform-tools) and a phone with USB debugging | the on-phone part |
| [PCAPdroid](https://f-droid.org/packages/com.emanuelef.remote_capture/) on the phone | the network check |
| [`glab`](https://gitlab.com/gitlab-org/cli), logged in to gitlab.com | posting the report |

Only the first two rows are required. Without a phone, PCAPdroid or `glab`,
the script turns that part off, and the report leaves those boxes for you.

`aapt2` is found on `PATH`, or under `$ANDROID_HOME` / `$ANDROID_SDK_ROOT` /
`~/Android/Sdk`.

## Setup

1. On the phone, turn on Developer options and **USB debugging**, then
   connect it and accept the "Allow USB debugging" prompt.
2. Install **PCAPdroid** from F-Droid on the phone.
3. Log `glab` in to gitlab.com with a token that has the `api` scope:
   `glab auth login --hostname gitlab.com`.
4. Check everything:

   ```sh
   ./fdroid-tester.sh --check
   ```

A second user profile on the phone (Settings → System → Multiple users) keeps
the apps you test away from your own data.

## Usage

```sh
./fdroid-tester.sh <merge request link or number> [options]

  -s SERIAL      the adb device to use, when more than one is connected
  -w SECONDS     how long to watch the app after it opens (default 15)
  --no-device    only download and look inside the APK, no phone needed
  --keep         leave the app installed at the end without asking
  --check        only check the tools, the phone, PCAPdroid and glab, then stop
  --version      print the version
```

Merge requests waiting for a tester, oldest first:
[review-requested](https://gitlab.com/fdroid/fdroiddata/-/merge_requests/?sort=created_asc&state=opened&label_name[]=review-requested).

The first time PCAPdroid is started from the computer, the phone asks you to
allow it, and Android asks to allow its VPN. Allow both, then press Enter in
the terminal once the capture is running.

### Output

In the folder you run it from:

```
com.example.app_123.binary.apk          the APK that was tested
com.example.app_123-review/
  report.md                             the report, as posted
  codequality.json                      the merge request's Code Quality report
  com.example.app.yml                   the metadata from the merge request
  traffic.pcap                          the app's traffic (PCAPdroid)
  after-15s.png, permission-on-start.png
  crash.log                             if it crashed
```

### Optional keys

One line each, nothing else in the file, in `~/.config/fdroid-tester/`:

- `pcapdroid-api-key`: PCAPdroid starts without the prompt on the phone.
  Create the key in PCAPdroid → Settings → Control permissions → menu.
- `virustotal-api-key`: the VirusTotal result for the APK's hash goes into the
  report. Without it, the report has a link to check by hand. Only the hash is
  sent; the APK itself is not uploaded.

## Good to know

- CI deletes the APKs after a while. If the download fails, ask the author on
  the merge request to re-run the pipeline.
- The checks inside the APK are hints, not verdicts. An address in the code is
  not always contacted, and a `releases/latest` link may be a download button
  rather than an update check. The report says what was found; you decide.
- The traffic capture shows **where** the app connects, not what it sends.
  HTTPS stays encrypted.
- Nothing is posted without your yes, and you can edit the report first.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
