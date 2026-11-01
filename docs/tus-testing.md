# TUS migration and container test results

Verified on 1 November 2026 using OpenCloud rolling 9.0.0, Immich v3.3.5, POSIX storage and a generated OpenCloud app token on macOS arm64. The stack, accounts, volumes and file content were disposable. No Finder or File Provider interactions were performed.

## Implementation

All production file-content creates and edits now use TUS. `OpenCloudRemote.upload` replaces the former `put` operation. The uploader POSTs the exact relative filename and SHA-1 metadata, records the returned session URL, queries its accepted offset with HEAD and sends PATCH chunks of at most 8 MiB. Empty files use OpenCloud's TUS zero-byte handling. WebDAV remains for metadata, downloads, directories, MOVE and DELETE; Libre Graph sharing is unchanged. There is no production PUT fallback.

SyncEngine places the TUS checkpoint beside the operation manifest in its private Recovery directory. Checkpoints bind the source digest, destination, server/username and base revision. Lost chunk responses resume using the server offset. A completed upload can survive a subsequent metadata failure without being uploaded again. Expired sessions and lost creation responses remain pending for recovery rather than creating another session automatically. Final size, identity and content are verified before the operation is cleared.

## Verification summary

| Check | Result |
| --- | --- |
| `sh scripts/check.sh` | Passed: 64 core tests, package build, generated project and plist validation |
| Functional container suite | 9 tests completed: 6 normal passes and 3 strict expected server failures |
| Immich-offline container suite | 1 normal pass |
| Upstream upload contracts | 14 tests: 3 passed and 11 failed, without expected-failure suppression |
| Complete container command | Exit 1 because the upload contract suite reproduced server failures |

The functional suite passed real chunk resumption after losing an accepted PATCH response, reopening the catalog and constructing a new API client/session. It resumed at byte 2 with PATCH offsets 0, 2, 4, 6 and exactly one POST; the first chunk was not replayed. Empty-content replacement preserved the file ID and downloaded as zero bytes. File round trips, moves, durable recovery, Immich indexing/albums/links and operations while Immich was stopped also passed.

The three functional expected failures remain create-only upload collision, stale DELETE and stale MOVE. Those checks document limitations; they do not establish successful conflict protection.

## Reva issue 866

The diagnostic suite reproduces [Reva #866](https://github.com/opencloud-eu/reva/issues/866). Its raw PUT requests are historical comparison probes only; production and fixture uploads use TUS.

| Request | Expected | Observed | Resulting content |
| --- | --- | --- | --- |
| TUS create-only upload to occupied filename | 412 | 201 | Existing content replaced |
| TUS empty create-only upload to occupied filename | 412 | 201 | Existing content emptied |
| TUS `If-Match` on missing file, nonempty | 412 | 201 | Missing file created |
| TUS `If-Match` on missing file, empty | 412 | 201 | Empty file created |
| TUS `If-Match: *` on existing file | 201 | 412 | Original retained; valid upload rejected |
| TUS stale ETag on existing file, nonempty | 412 | 412 | Original retained |
| TUS stale ETag on existing file, empty | 412 | 412 | Original retained |
| PUT create-only upload to occupied filename | 412 | 204 | Existing content replaced |
| PUT empty create-only upload to occupied filename | 412 | 204 | Existing content emptied |
| PUT `If-Match` on missing file, empty | 412 | 201 | Empty file created |
| PUT `If-Match` on missing file, nonempty | 412 | 412 | File remained absent |
| PUT `If-Match: *` on existing file | 204 | 412 | Original retained; valid upload rejected |

Nine of these twelve cases failed. TUS did not resolve the reported create-only and missing-target conditions. The production client uses exact ETags, not the wildcard update condition; that wildcard is included to reproduce the upstream protocol contract.

## Reva issue 959

The suite exercises both [Reva #959](https://github.com/opencloud-eu/reva/issues/959) creation-with-upload and the separate-session sequence used by the new production uploader.

- In the final ten-round creation-with-upload run, **10/10 rounds returned 201 for both competing uploads** based on the same ETag. The preceding run reproduced double success in 7/10 rounds, demonstrating timing sensitivity. Only one writer's content was current after each race.
- In the separate-session test, both upload sessions were created before either sent its final PATCH. **Both PATCHes returned 204**, rather than one succeeding and the other returning 412. The later committed content was current.

The latter result establishes that splitting POST from PATCH does not avoid the race. Our final content verification can detect some intervening changes, but cannot prevent an already-verified upload from being overwritten later by another session. These tests do not verify whether the losing content is recoverable from server history.

## Running and interpreting the suite

```sh
sh scripts/check.sh
python3 scripts/container-e2e.py
```

The container runner completes all three suites, writes `results.json` and individual test logs under `build/container-e2e/<project>/`, and removes its containers, networks and volumes even when assertions fail. The JSON includes test outcomes, expected-failure counts, expected/observed response statuses and the synthetic final content. The upstream contract failures remain normal failures, so an overall unsuccessful run on OpenCloud 9.0.0 is expected until the server behavior changes.

Protocol references: [OpenCloud TUS API](https://docs.opencloud.eu/docs/dev/server/apis/http/tus_upload/) and [TUS resumable upload protocol](https://tus.io/protocols/resumable-upload).
