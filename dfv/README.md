<!-- NIOGEN | dfv/README.md | 11/11/2026 — Claude Code (docs/Prompt_operador_dfv_cobertura_111126_1520.md)
     Resumo: operador DFV (Chromium logado no painel "DFV Sudeste" da Nio) + edge function dfv-consulta + tela Cobertura.
     Consulta-só: não grava nada na venda, não mexe na Mari nem no n8n. -->

# Operador DFV — Cobertura ao vivo

## Caminho de uma consulta
`cobertura.html` → `NG.dfvAoVivo()` → edge function **`dfv-consulta`** (usuário logado) → `GET {DFV_OP_URL}/dfv?cep=&numero=&complemento=[&uf=&municipio=]`
com `Authorization: Bearer DFV_OP_TOKEN` → operador **`niogen-dfv`** na VPS do n8n → JSON.
Operador sem resposta em 12 s (`DFV_OP_TIMEOUT_MS`) ou com erro → a função chama a RPC `dfv_consultar` (base congelada de JF, `nio_hp`)
e devolve `{fonte: 'base_congelada', motivo, particao, rpc}`; a tela mostra a faixa "Base congelada de JF (DD/MM)".

## Como o operador lê o painel (medido em 11/11)
1. Login como o humano: usuário **PARCEIRO** → Senha 1 + Enter → Senha 2 + Enter (aviso "ok") → ENTRAR → página "3 de 4" (Mapa de Classificação).
   ~17 s no PC, ~45 s na VPS (1 vCPU). Feito ao subir e de novo quando um pedido falha.
2. Ao abrir a página 3 o próprio painel pede a **grade** de fachadas, o **mapa** (lat/long) e a **data da base**. O operador guarda esses
   pedidos (já com os filtros do login) como modelo e larga o relatório (vai para `app.powerbi.com/robots.txt`, mesmo domínio — ~170 MB a menos).
3. Cada consulta repete o pedido do painel **de dentro da página**, trocando só os filtros UF / CEP (/ MUNICIPIO) e sem o TopN da grade:
   **0,5–0,9 s**. Uma consulta traz todas as fachadas viáveis do CEP; número e complemento são casados no operador. Cache de 10 min por CEP.
4. Se o painel recusar (Nio republicou) → novo login (recaptura os modelos) → se falhar de novo, **caminho da tela**: Limpar Filtros,
   UF / MUNICIPIO / CEP pelos slicers e leitura da grade (`role=grid`) — ~21 s, sem lat/long.
Nada de assinatura, token ou bloqueio contornado: é o pedido que a página publicada faz, com a chave pública dela.

## Resposta (`GET /dfv`)
`consultado_em, atualizado_painel (DD/MM/AAAA), fonte 'ao_vivo', metodo (painel|cache|tela), ms, entrada, match (exato|sem_numero|nao_encontrado),
viabilidade (viavel|rua_viavel|nao_encontrado), faixa_credito_bairro, bairro, logradouro, celula, classificacao, fachada, unidades,
fachadas_no_cep[≤300] {numero, complemento…, viabilidade, hps, hp_livre, hcs, celula, bairro, logradouro, faixa_credito, lat, lon},
total_fachadas_no_cep, regra_200m {status: dentro|nao_avaliada_v1|indefinido, nota, vizinha_mais_proxima}`.
**Número fora da lista nunca vira "sem viabilidade"** (vale a regra dos 200 m). A faixa de crédito é do **bairro**, não do CPF.

### Regra dos 200 m — gancho da v2
O painel já dá lat/long das fachadas viáveis (`fachadas_no_cep[].lat/lon`). Falta a posição do endereço do cliente (geocodificar o endereço).
Com ela: `haversine_m()` (já no `operador.py`) até a fachada viável mais próxima → `dentro`/`fora`. TODO marcado em `montar()`.

## Instalação (VPS do n8n, `/opt/niogen/dfv/`)
- Arquivos: `operador.py`, `Dockerfile`, `docker-compose.yml`, `testar.sh`. Rede `renata_web`, sem porta publicada, `mem_limit 900m`.
- `.env` (chmod 600, fora do repo; gravado por pipe a partir de `config_links.acesso`, sem aparecer na tela):
  `DFV_URL`, `SDE_USUARIO`, `SDE_SENHA1`, `SDE_SENHA2`, `DFV_OP_TOKEN`.
- Subir/atualizar: `cd /opt/niogen/dfv && docker compose up -d --build`. Aceite: `sh testar.sh`.
- Rota pública: `https://n8n.ofertasverointernet.com.br/niogen-dfv/*` → `niogen-dfv:8091` (bloco `handle_path` no Caddyfile da Renata,
  `/opt/renata/Caddyfile`). **O operador exige o Bearer em toda rota**; sem ele, 401.
- Edge function: segredos `DFV_OP_URL`, `DFV_OP_TOKEN`, `DFV_OP_TIMEOUT_MS` (Supabase › Edge Functions › Secrets).
- Testar local (PC com Chrome): `DFV_CHROME_CANAL=chrome` + as variáveis acima → `python operador.py teste 36010000 241`.

## Fora do escopo (próximas rodadas)
Gravar `dfv_*` na venda e os triggers `vendas_antes_cobertura`/`vendas_antes_dfv` (a venda segue na `dfv_consultar`) · a Mari usar o
operador (o endpoint já serve) · crédito por CPF.
