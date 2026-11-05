<!-- NIOGEN | n8n/NIO_PORTAL_VIABILIDADE_em_espera_051126.md | 05/11/2026 — Claude Code (prompt nº 15, parte A)
     Resumo: por que o workflow nio_portal_viabilidade (nível A) NÃO foi criado e o que destrava. -->

# `nio_portal_viabilidade` — nível A em espera (05/11/2026)

## O que o prompt 15 supunha
Login do portal PAP por API: `POST /api/portal/loginbo` com matrícula + senha → token → `novafibra/endereco` → polling → `posseSalesforce`.

## O que existe de verdade (lido no bundle público `pap.niointernet.com.br/administrativo/bundle.js`, sem login)
- `GET /api/portal/loginbo` **não é login**: só diz se o "login simulado" está habilitado (`data.habilitado`). Sem token responde `{"code":4011,"message":"jwt must be provided"}`.
- O login simulado (`POST /login/signin` com `{matricula, senha, appVersion:"N/A", origem:"BO"}`) está **desligado** em produção (`Cannot POST /login/signin`).
- O login real do BO é **SSO Microsoft (SAML)**: `GET /auth/saml/login?origem=bo` devolve um formulário que posta para `login.microsoftonline.com/<tenant da Nio>/saml2`; a volta é `/auth/saml/login/callback?origem=bo`.
- O front monta o `Authorization` como `token + sufixo cifrado com a hora` (`_getAuthorizationToken`, `encodeObjectBase64Xor`).

**Conclusão:** o n8n não consegue entrar no portal sozinho de forma confiável (SSO Microsoft, possível MFA/acesso condicional, e o sufixo cifrado do front). Pela regra do próprio prompt ("se o login não for automatizável, o nível A espera"), **o Ricardo decidiu em 05/11: nível A em espera**.

## O que ficou pronto (migration `0023`)
- `vendas.nio_viab_*` (resultado, velocidade, interesse, endereço, em, origem) e `mari_conversas.nio_viab_*`.
- `nio_viab_log` (auditoria + cache de 7 dias por `cep|numero|complemento`, RLS: só admin/backoffice leem; só service_role grava).
- Trava 0 → 1 aceita viabilidade oficial viável < 7 d **ou** DFV viável < 7 d.
- Prompt v4 da Mari trata `nio_viab_resultado` (viável · sem viabilidade · posse · indisponível); enquanto o nível A não existe, o motor manda sempre **indisponível** → fala por cidade + DFV (comportamento da v3).
- NIOGEN: campo "Interesse no portal" e viabilidade **manual** (quem consulta no portal registra o resultado na ficha, origem `manual`).

## O que destrava
1. **Usuário de integração** da Nio (API key ou client credentials) para consulta de viabilidade — pendência no Diário.
2. Com ele: criar o workflow `nio_portal_viabilidade` (inativo), credencial n8n "Portal PAP Nio (integração)", rota `POST /webhook/nio-viabilidade` (header `X-Mari-Secret`), passos 2–8 do prompt 15 (endereço → consultaEnderecos → selecionar → complementos → referência → polling 1 s/30 s → `viabilidades/v2` + `posseSalesforce` → mapear), limites (1 consulta por conversa/endereço, cache 7 d, 429/5xx = `indisponivel` e 10 min sem repetir), `tests/nio_viabilidade_testes.py`.
3. No motor da Mari: trocar o `indisponivel` fixo do `4 · Preparar` pela chamada (Execute Workflow, timeout 30 s, balão "deixa eu só conferir aqui" após 6 s).

**Não fazer:** copiar token de sessão do navegador para o n8n, reproduzir o sufixo cifrado do front ou automatizar o login Microsoft. Nível C (pedido, crédito, biometria, OS) continua proibido sem autorização escrita da Nio.
