# مصروفي — Masroufy

A multi-user expense tracker. The web server, authentication, authorization, SQLite queries and monthly totals are implemented in **Haskell**. The interface is Arabic, responsive, and uses plain HTML/CSS/JavaScript.

## Run on Windows

Install GHC and Cabal through GHCup, then open PowerShell in this directory:

```powershell
cabal update
cabal run masroufy
```

Open http://127.0.0.1:3000. Alternatively run `./start.ps1`. The first build downloads dependencies and takes a few minutes. Create your own account using Sign Up; no default users or passwords are shipped.

To use another port: `./start.ps1 -Port 3002`.

## Features

- Sign up, log in, persistent server-side sessions, and log out.
- Each account has its own expenses and monthly budgets.
- Create, edit, delete and filter expenses by month/category/note.
- Monthly dashboard, remaining budget, category distribution and period chart.
- Profile name editing.
- Egyptian pounds, stored and calculated as integer piastres (100 piastres = EGP 1).

## Code map

- `app/Main.hs`: Scotty routes, input validation, Argon2id passwords, session/CSRF checks, owner-scoped SQLite statements, monthly totals.
- `static/index.html`: Arabic interface and dialogs.
- `static/style.css`: responsive styling.
- `static/app.js`: API calls and UI rendering.
- `test/integration.py`: isolated end-to-end HTTP tests, including two-account isolation.
- `data/masroufy.sqlite`: created automatically on first start. Contains real account data; do not commit or share it.

## Tests

Build first, then run with Python 3:

```powershell
cabal build
python test/integration.py
```

The test script starts an isolated server on port 3099 with a temporary database and deletes that database afterward. It does not modify your normal database. It checks sessions, invalid credentials, CSRF, ID guessing across accounts, exact totals, validation, updates, persistence, deletion and rate limiting.

## API

Authentication: `POST /api/signup`, `POST /api/login`, `GET /api/me`, `POST /api/logout`.
Expenses: `GET|POST /api/expenses`, `PUT|DELETE /api/expenses/:expenseId`.
Budget: `GET /api/budgets`, `PUT /api/budget`.
Summary: `GET /api/summary?month=YYYY-MM`. Profile: `PUT /api/profile`.

All write calls use JSON. Login and signup require `X-Requested-With: Masroufy`. Authenticated writes additionally require `X-CSRF-Token`, returned by login/signup/me. Browser sessions use an HttpOnly, SameSite=Strict cookie; the server determines the user ID from that session. Owner IDs sent by clients are never used.

## Deployment configuration

This project runs locally by default, bound to 127.0.0.1. Environment variables:

- `PORT`: default 3000.
- `HOST`: default 127.0.0.1.
- `DATABASE_PATH`: default data/masroufy.sqlite.
- `SECURE_COOKIE=1`: enable Secure cookies when serving over HTTPS.

For internet hosting, use an HTTPS reverse proxy, set SECURE_COOKIE=1, and keep the application port private. SQLite suits this small single-server project; authentication throttling is in memory and resets on restart. Back up the database safely. Password reset and email verification are not included in this first version.
