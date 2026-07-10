# Phase 0 Research Findings

## MovieBlast API — VALIDATED ✅

### Search Endpoint
```
GET https://app.cloud-mb.xyz/api/search/{query}/{token}
Headers: hash256, packagename, signature, User-Agent: MovieBlast
Response: {"search": [{"id":875,"name":"Inception","poster_path":"...","type":"movie|series"}]}
```

### Detail Endpoint
```
GET https://app.cloud-mb.xyz/api/media/detail/{id}/{token}
Response: {"videos": [{"id":1898,"server":"720P","link":"mblinkmove.mycdn-mb.xyz/...","lang":"Telugu"}]}
```

### URL Signing (CRITICAL)
Links are Cloudflare-protected. Must sign with HMAC-SHA256:
```bash
# HMAC secret and signing logic live in ~/.config/movie-cli/movieblast.conf
# See movieblast.sh _mb_sign_url() for the signing implementation
```

### Token Values (from Kotlin source, base64 encoded)
# All credential values: ~/.config/movie-cli/movieblast.conf
# Source: Cloudstream MovieBlast extension (public Kotlin source)

### Languages Available
- Telugu (primary)
- Other Indian languages may be available for other titles

### Qualities
- 720P, 720P - 1.6GB, 360P

## TMDB API — Requires API Key

```
GET https://api.themoviedb.org/3/search/multi?query=inception&api_key=KEY
Response: {"status_code":7,"status_message":"Invalid API key"}
```

Free tier: 40 requests per 10 seconds. Key needed for CineStream plugin (v0.2+).

## Decision Gate

| Source | Status | Can Play? | Notes |
|--------|--------|-----------|-------|
| MovieBlast | ✅ Working | ✅ Yes (with signing) | Primary source for v0.1 |
| TMDB + Embeds | ⚠️ Needs API key | ❓ Untested | Defer to v0.2 |
| CineStream | ❓ Not tested | ❓ Unknown | Defer to v0.2 |

**Decision: Ship v0.1 with MovieBlast only. CineStream deferred to v0.2.**
