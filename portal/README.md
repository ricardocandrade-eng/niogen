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

## Crédito — operador de consulta (11/11/2026, `docs/Prompt_operador_credito_consulta_111126_1650.md`)
**Autorização:** Rogério (gerência SDE MG, 11/11) — consulta de crédito antecipada, **só consulta**; Ricardo 11/11 16h15/16h41.
O operador passa as Etapas 1–4 do **Novo Pedido** na tela (como o humano) e **lê** a Etapa 5. Nunca Avançar na 5, nunca
**Salvar interesse**, nunca Resumo/OS/biometria/pagamento. Não usa `/chamar` nem mexe em `PERMITIDOS`/`PROIBIDOS`.

| Peça | O quê |
|---|---|
| `credito.py` | fluxo (Etapas 0–5), travas de clique (`clicar()` — lista negra + Avançar só nas etapas 1–4) e de rede (`page.route`), leitura do popup/radios/ofertas, amostras redigidas |
| `servico.py` | `ThreadingHTTPServer` + **uma thread do navegador com fila**; `POST /credito` → 202 `{job_id, posicao_fila}`; `GET /credito/{job_id}`; fila máx. 3; cache 24 h por CPF (sha256 + sal, só memória) |
| `testar_travas.py` | prova as travas sem navegador → `VERDE` |

**`.env` (fora do repo; nada fixo no código — regra 15):** `CREDITO_MATRICULA` (TT837725) · `CREDITO_END_CEP` / `CREDITO_END_NUMERO` /
`CREDITO_END_REFERENCIA` (endereço viável padrão: 36013-260, 420, Centro JF) · `CREDITO_CONTATO_CELULAR` / `CREDITO_CONTATO_EMAIL`
(contato padrão do backoffice — o Ricardo passa) · `CREDITO_LIMITE_HORA` (20) · `CREDITO_LIMITE_DIA` (60) · `CREDITO_SAL` (sal do hash;
sem ele usa o segredo do serviço) · `CREDITO_AMOSTRAS_DIR` (`/amostras` no container).

**Exceção na trava de rede (11/11, aceite):** a Etapa 5 consulta sozinha `portabilidadenovafibra/consultaDDDPorUF/<UF>` e
`.../consultaOperadoras` (portabilidade do móvel, só leitura); barrar quebra a tela ("OPS, OCORREU UM ERRO!"). Só rotas
`portabilidadenovafibra/consulta…` passam (`LIBERADOS` em `credito.py`); qualquer outra rota de portabilidade segue barrada.

**Aceite (11/11, PC do Ricardo):** Felipe → `pedido_em_andamento` na Etapa 3 (13 s) · Ricardo → `aprovado_todas` na Etapa 5 (22 s) ·
repetição → `cache: true` (0 ms) · log e amostras sem CPF/nome/contato.

**Resultados:** `aprovado_todas` · `aprovado_cartao` · `aprovado_parcial` · `pendente` · `negado` · `pedido_em_andamento` · `sem_viabilidade` ·
`erro_receita` · `nao_classificado` · `erro`. Só os seis primeiros vão para o cache de 24 h (os outros podem ser refeitos).
Log: `credito <job> · origem · resultado · ms · etapa` (stdout e `amostras/credito_log.jsonl`) — **nunca** CPF, nome, telefone ou e-mail.

**Amostras (temporário):** respostas de `analiseCredito|propostaCredito|elegibilidade|duplicidadepedido` com toda chave pessoal
redigida, um JSON por consulta em `amostras/` (apagadas com mais de 7 dias). Servem para mapear `negado`, `pendente` e `aprovado_cartao`
no primeiro caso real — conferir a classificação e avisar o Ricardo.

**Rodar no PC (fase 0, IP do Brasil, enquanto a VPS BR não existe):**
```
set NIO_PORTAL_ENV=C:\Users\ricar\niogen-local\portal\.env
set NIO_PORTAL_CANAL=chrome
set CREDITO_AMOSTRAS_DIR=C:\Users\ricar\niogen-local\portal\amostras
python portal\servico.py
curl -s -X POST 127.0.0.1:8090/credito -H "X-Portal-Secret: <segredo>" -H "Content-Type: application/json" -d "{\"cpf\":\"<cpf>\"}"
curl -s 127.0.0.1:8090/credito/<job_id> -H "X-Portal-Secret: <segredo>"
```
O `.env` local leva `NIO_PORTAL_USER`, `NIO_PORTAL_PASS`, `NIO_PORTAL_DOMINIO=vtalcorp.onmicrosoft.com`, `NIO_PORTAL_SERVICO_SECRET` e os `CREDITO_*`.
`NIO_PORTAL_HEADLESS=0` mostra a janela do Chrome (bom para o 1º aceite).

**Caminho da tela até o operador (quando a VPS BR existir):** edge function `credito-consulta` → `CREDITO_OP_URL` = rota no Caddy da
VPS do n8n (`/opt/renata/Caddyfile`, `handle_path /niogen-credito/*` → `niogen-portal-tunel:8090`, repassando **só** `/credito` e
`/credito/*`) → túnel SSH → `127.0.0.1:8090` na VPS BR. `/chamar` e `/renovar` não ficam expostos.
