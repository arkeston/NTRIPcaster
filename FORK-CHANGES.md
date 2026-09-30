# Fork changes — details

Fork of [`Rampump/NTRIPcaster`](https://github.com/Rampump/NTRIPcaster), base commit `1bceb9b`
(2RTK Ntrip Caster 2.2.0). Maintained by [@arkeston](https://github.com/arkeston).

---

## 1. English localization (720 units)

The upstream build ships Chinese for every user-visible string: log lines, NTRIP API responses, web-UI labels
and the container entrypoint messages.

| Step | Scope | Units |
|---|---|---|
| 1 | Python string literals + Chinese fragments in HTML/JS longer than one character | 556 |
| 2 | leftovers, including single-character fragments | 124 |
| 3 | `entrypoint.sh`, `config.ini` comments, fragments inside already-translated literals | 36 |
| 4 | 4 strings that the translation API refused (commented-out code) — translated manually | 4 |

Result: `front/sh/ini` files contain **0** Chinese characters, the login page contains **0**, fresh log lines
contain **0**. Python comments and docstrings are deliberately left in Chinese — they are not user-visible and
translating them would make the diff unreviewable.

Translation memory (Chinese → English, 720 entries) and the scripts that produced and applied it live in our
infrastructure repository next to this fork; the fork itself contains the **applied** result.

## 2. Anonymous read access

**Goal:** anyone may *receive* NTRIP (with no credentials, or with arbitrary credentials), while a base station
may *publish* only with valid NTRIP authentication.

Implementation — three small insertions:

| File | What was added |
|---|---|
| `src/config.py` | `ANONYMOUS_READS` / `ANONYMOUS_MOUNTS`, read from environment variables `NTRIP_ANONYMOUS_READS` / `NTRIP_ANONYMOUS_MOUNTS` and from `[ntrip] anonymous_reads` / `anonymous_mounts` |
| `src/database.py` | `is_anonymous_mount(mount)` — true if the mount point is listed (exact name, `prefix*`, or `*` for all) **or** its password is `public` / `anonymous`; the mount point must exist. Plus the matching `DatabaseManager` method |
| `src/ntrip.py` | early return in `verify_user()` **only** for `request_type == "download"`: anonymous reads are allowed, and the session is logged as `anonymous_<mount>`. Uploads (`SOURCE`) never take this path |

Because the check sits in `verify_user()` before every protocol branch, it works the same for NTRIP 0.8/1.0/2.0
and RTSP clients.

**Verified** (sandbox container against a copy of a production database, then live on the master caster):

| Test | Expected | Result |
|---|---|---|
| read public mount point, no credentials | allow | `ICY 200 OK` |
| read public mount point with garbage credentials | allow | `ICY 200 OK` |
| read closed mount point, no credentials | deny | `SOURCETABLE 401 Unauthorized` |
| `SOURCE` public mount point, no credentials | deny | `SOURCETABLE 401 Unauthorized` |

## 3. Bug fix: `config.ini` was ignored

`src/config.py::get_config_value()` asks for lowercase sections (`get_config_value('database', …)`,
`get_config_value('ntrip', …)`), while the shipped `config.ini` / `config.ini.example` use uppercase section
names (`[DATABASE]`, `[NTRIP]`). `configparser` is case-sensitive, so **every** lookup raised and fell back to
its default: database path, secret key, ports, limits, logging paths — all silently ignored.

Fix: `_cfg_resolve(section, key)` finds the real section/key name ignoring case, and `get_config_value()` uses it.

⚠️ Note when deploying: this fix *activates* the config file. Check `[DATABASE] path` points where you want the
SQLite file (upstream default is `/app/data/2rtk.db`; a container that bind-mounts `/app/2rtk.db` must say so).

## 4. How this fork is used in production (reference)

* one caster instance (master) with the SQLite database on a host bind-mount, an hourly consistent snapshot and
  a cold standby copy on two reserve sites;
* the other sites have no container: `haproxy` forwards `2101/tcp` to the master and Caddy proxies the web UI to
  the master over TLS (`header_up Host <name>` is required, otherwise Caddy on the master answers an empty 200);
* images are committed from a normally started container with explicit `ENTRYPOINT`/`CMD`
  (`docker commit` bakes the entrypoint/cmd of the committed container — committing a container that was started
  with `--entrypoint sh … sleep` produces an image that sleeps instead of running the caster).

## 5. Known issues / roadmap

* **No UI setting for anonymous access yet** — it is configured by mount-point password, environment variables or
  `config.ini`. Planned: a switch in the *Settings* section plus a per-mount "public read" checkbox (DB column
  `is_public`).
* **Slow startup** (5–30 s before the caster accepts connections) — under investigation.
* `healthcheck.py` queries `/health`, which returns 404; run containers with `--no-healthcheck` or add the endpoint.
* The server database is SQLite only; PostgreSQL/MySQL appear in `config.ini.example` but are not implemented.
