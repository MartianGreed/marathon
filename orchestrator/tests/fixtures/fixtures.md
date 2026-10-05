Fixtures produced 2026-10-05 by the real `orchestrator/src/auth/auth.zig` at base 3893174 with Zig 0.15.2 (macOS arm64), via:

zig run --dep auth -Mroot=gen.zig --dep common -Mauth=<lane-b>/orchestrator/src/auth/auth.zig -Mcommon=stub.zig

(stub.zig only provides `types.ClientId`/`formatId` so auth.zig compiles alone; PasswordHash and Jwt don't use them.)

- Password: `zig-compat-password`
- PBKDF2_HASH (`PasswordHash.hash`): `b9501776fc89a4fb1f1338b17d84b385:b95ddb619d0b4d5a83a7a9f1c1fc7cd4fd873672bdf0d3fb2d6906f3894da126`
- Zig verify(self)=true, verify("wrong")=false
- JWT secret: `zig-compat-jwt-secret`, user id bytes 0xa0..0xaf (hex `a0a1a2a3a4a5a6a7a8a9aaabacadaeaf`), email `zig@example.com`
- JWT (`Jwt.create`, exp = now + 100 years, exp 4944792045): `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhMGExYTJhM2E0YTVhNmE3YThhOWFhYWJhY2FkYWVhZiIsImVtYWlsIjoiemlnQGV4YW1wbGUuY29tIiwiaWF0IjoxNzkxMTkyMDQ1LCJleHAiOjQ5NDQ3OTIwNDV9.01YIXIuiJ6d8RtcP_DPFYqD27ONSJiProg5KRSUQwGI`
- JWT_EXPIRED (exp = iat - 3600, exp 1791188445): `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhMGExYTJhM2E0YTVhNmE3YThhOWFhYWJhY2FkYWVhZiIsImVtYWlsIjoiemlnQGV4YW1wbGUuY29tIiwiaWF0IjoxNzkxMTkyMDQ1LCJleHAiOjE3OTExODg0NDV9.rFYWY_h0hanYJb2ySaAb-te5r6YadTjfumf-VR75B60`
