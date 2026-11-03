---
name: rate-limiting-go
description: Rate limit Go HTTP APIs
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
---

# Rate Limiting for Go HTTP Services

Implement rate limiting in Go HTTP services using token bucket algorithm, specifically for API key-based endpoints.

## When to Use
Use when implementing rate limiting for authenticated API endpoints in Go services, particularly when using middleware patterns with routers like chi or gin.

## Procedure

1. **Add rate limiter dependency to state**
   - Add `ratelimiter *ratelimit.Limiter` field to your application state struct
   - Import the rate limiting package: `"github.com/yourmodule/services/ratelimit"`

2. **Configure rate limiter from environment**
   - Add configuration fields to your Config struct:
     - `RateLimitCapacity int` (default: 10)
     - `RateLimitRefillSeconds int` (default: 1)
   - Load these from environment variables with sensible defaults
   - Initialize limiter in state creation function when both values > 0:
     ```go
     if cfg.RateLimitCapacity > 0 && cfg.RateLimitRefillSeconds > 0 {
         st.ratelimiter = ratelimit.New(cfg.RateLimitCapacity, time.Duration(cfg.RateLimitRefillSeconds)*time.Second)
         slog.Info("rate limiter configured", "capacity", cfg.RateLimitCapacity, "refillSeconds", cfg.RateLimitRefillSeconds)
     }
     ```

3. **Create or enhance authentication middleware**
   - Extract API key from Authorization header: `strings.TrimPrefix(authHeader, "Bearer ")`
   - Call your auth resolution function to validate the key and get principal
   - Only proceed to rate limiting if auth succeeds

4. **Implement rate limiting check in middleware**
   - After successful auth, check if rate limiter is configured (not nil)
   - If configured, call `st.ratelimiter.Allow(apiKey)`
   - If not allowed, return HTTP 429 (Too Many Requests) with appropriate error message
   - If allowed, proceed to next handler

5. **Handle edge cases**
   - Gracefully handle missing or malformed Authorization headers
   - Ensure rate limiting doesn't break when limiter is nil (disabled)
   - Log rate limiter configuration at startup for visibility
   - Preserve existing request context and principal when rate limiting passes

## Pitfalls to Avoid

- **Don't rate limit before authentication** - Always validate the API key first to avoid limiting based on invalid/missing keys
- **Don't forget to return after rate limit error** - Immediately return HTTP 429 without calling next handler when limit exceeded
- **Don't use incorrect header parsing** - Always use `strings.HasPrefix(auth, "Bearer ")` before extracting the token
- **Don't neglect context propagation** - When rate limiting passes, ensure the authenticated principal is properly attached to request context for downstream handlers
- **Don't hardcode limits** - Make capacity and refill rate configurable via environment variables for different deployment environments
- **Don't ignore zero values** - Only initialize and use the rate limiter when both capacity and refill seconds are positive values

## Verification

- Test that valid requests under the limit succeed (200 OK)
- Test that requests exceeding the limit are rejected with 429 status
- Test that the limit resets correctly after the refill period
- Test that missing/invalid Authorization headers are handled by auth middleware before rate limiting
- Test that disabling rate limiting (setting capacity or refill to 0) disables the check

## References

- Token bucket algorithm implementation: see `services/ratelimit/ratelimit.go`
- Example integration: see `apps/api/main.go` apiKeyMiddleware function
- Configuration pattern: see `services/config/config.go`
