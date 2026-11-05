<!-- NIOGEN | portal/README.md | 05/11/2026 — Claude Code (prompt nº 16)
     Resumo: login do portal PAP por navegador (Playwright) e o "operador" que executa a viabilidade oficial (nível A)
     dentro da página do portal, numa VPS no Brasil. Estado, decisões e o que falta. -->

# Portal PAP — login por navegador e operador da viabilidade (nível A)

## O que foi provado em 05/11 (VPS do n8n, Nova Jersey)
- **Login automático funciona**: `tt837725@vtalcorp.onmicrosoft.com` (o `.env` guarda só a matrícula; o domínio vem de
  `NIO_PORTAL_DOMINIO`), senha, tela **"Continuar conectado?" → Sim**, volta ao portal em 8–16 s. Sem MFA.
- O callback SAML devolve o token na rota **`/administrativo/login-callback/<jwt>`**; o front grava o cookie `token`.
- **O front `pap.niointernet.com.br` bloqueia IP de fora do Brasil** (403 até no `bundle.js`); a API `pap-api` responde.
- **A API recusa o token puro** (`4011 invalid signature`): cada chamada leva o sufixo cifrado com a hora que o front
  cola (`_getAuthorizationToken`).
- **Decisão do Ricardo (05/11):** rodar de um **IP do Brasil** e executar as chamadas **dentro da página** (Plano B),
  com a função do próprio front — nada de reproduzir o sufixo nem de contornar o bloqueio de IP.
- O gancho (`GANCHO_JS` em `portal_login.py`) captura a função do front quando o webpack a registra — testado no
  front aberto: `typeof window.__ngAuthGetter() === 'function'`.

## Peças
| Arquivo | Onde roda | O quê |
|---|---|---|
| `portal_login.py` | container `niogen-portal` | login SSO, gancho, `chamar()` com **lista do nível A** (nível C recusado), CLI `diagnostico` |
| `servico.py` | container `niogen-portal` (VPS BR) | HTTP 1 thread: `GET /saude`, `POST /renovar`, `POST /chamar` — header `X-Portal-Secret` |
| `Dockerfile`, `docker-compose.yml` | VPS BR `/opt/niogen/portal/` | imagem Playwright 1.48 + porta só em `127.0.0.1:8090` |
| `tunel/docker-compose.yml` | VPS do n8n `/opt/niogen/portal-tunel/` | túnel SSH → n8n chama `http://niogen-portal-tunel:8090` |

## Instalação (quando a VPS do Brasil existir)
**Ricardo:** Vultr › Deploy › Cloud Compute › **São Paulo** · Ubuntu 24.04 · 2 GB RAM (Chromium fica aberto) ·
SSH key = a mesma do PC (`id_ed25519_vero.pub`) · hostname `niogen-portal-br`. Mandar o IP.

**Claude Code:**
1. VPS BR: Docker, firewall só SSH (ufw), usuário `tunel` sem shell; `/opt/niogen/portal/` com estes arquivos;
   `.env` (600) com `NIO_PORTAL_USER`/`NIO_PORTAL_PASS` copiados por pipe da VPS do n8n (sem aparecer na tela) e
   `NIO_PORTAL_SERVICO_SECRET` novo; `chown` de `erros/` para o uid do `pwuser`; `docker compose up -d --build`.
2. `docker exec niogen-portal python portal_login.py diagnostico` → esperar `plano B` e `HTTP 200` em `permissoes`.
3. VPS do n8n: chave do túnel em `/opt/niogen/portal-tunel/`, `known_hosts` da BR, `authorized_keys` do `tunel` na BR com
   `permitopen="127.0.0.1:8090",no-pty,no-agent-forwarding,no-X11-forwarding,command="/bin/false"`; subir o túnel.
4. **Explorar os formatos** (uma consulta, endereço de teste 36013-260/420, Centro JF, comercial): abrir Novo Pedido na
   página do operador e registrar método/caminho/chaves do corpo de cada chamada (sem valores pessoais) — o prompt 15
   deixou os payloads de `POST novafibra/endereco` e da referência para capturar.
5. n8n: credencial "Portal PAP Nio (operador)" (header `X-Portal-Secret`); workflows **desligados**
   `nio_portal_sessao` (12 h + `POST /webhook/nio-portal-renovar` com `X-Mari-Secret` → `/renovar` → grava estado em
   `nio_portal_sessao`, sem token) e `nio_portal_viabilidade` (passos 2–8b do prompt 15 por `/chamar`, cascata,
   polling, `nio_viab_log`, cache 7 d, 429/5xx = pausa 10 min). Testes do prompt 16. Ligar só com o OK do Ricardo.

## Limites (prompt 16)
1 consulta por endereço por conversa · cache 7 d · nunca em laço (freio de 40 chamadas/min no serviço) · pausa de
10 min em 429/5xx · tudo assina como TT837725 (Datadog da Nio vê) · **nível C proibido** (lista em `PERMITIDOS`).
