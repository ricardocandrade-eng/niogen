<!-- NIOGEN | README.md | 03/11/2026 — o que é, como rodar local, como publicar -->

# NIOGEN — Renascer. Reconstruir. Crescer.

CRM da **Dharma Telecom**, agente credenciado PAP da **Nio Internet**. Front estático (HTML + CSS + JS puro,
sem build) sobre o **Supabase Nio**, que é o banco único (NIOGEN e Mari leem e escrevem no mesmo lugar).

**Publicado:** https://ricardocandrade-eng.github.io/niogen/ · Supabase Nio: `https://zlrfwbkblytnokuexjti.supabase.co`

Governança (Diário, INFRA, regras do contrato) fica na pasta do Drive `dharmapro-nio/`. O `CLAUDE.md` daqui é espelho do de lá.

## O que tem na v0

| Peça | Onde |
|---|---|
| Migration (tabelas, travas, eventos, views, RLS) | `supabase/migrations/0001_v0.sql` |
| Seed do admin (primeiro usuário do Auth → perfil admin) | `supabase/seed/usuarios_seed.sql` |
| Tabela vigente da Nio (planos, adicionais, bônus, vencimento calculado, área JF, municípios da GDP) | `supabase/migrations/0005_tabela_vigente_221026.sql` |
| Configurações › Tabela vigente (só leitura) | `docs/configuracoes.html#tabela` |
| Importação do OSAB (tabelas, `aplicar_osab`, metas, alertas, views do Painel) | `supabase/migrations/0003_importacao_osab.sql` · `0004` |
| Login → Painel | `docs/index.html` |
| Painel (aba Operação) | `docs/painel.html` |
| Configurações › Importação (OSAB com prévia) | `docs/configuracoes.html` · leitor `docs/assets/osab.js` |
| Funil 0→5 + Saída | `docs/funil.html` |
| Instalações por tempo | `docs/instalacoes.html` |
| Vendas + venda de rua | `docs/vendas.html` |
| Detalhe da venda | `docs/venda.html?id=` |
| Base DFV da Nio (`nio_hp`, `dfv_consultar`, `aplicar_dfv`, `v_dfv_bairros`, `v_dfv_resumo`, consulta automática na venda) | `supabase/migrations/0011_dfv_nivel3.sql` |
| Carga da base DFV pelo CLI (gera SQL fora do repo) | `supabase/scripts/dfv_carga.py` |
| Meta Ads › Bairros prioritários | `docs/metaads.html` |
| Contrato do RPC `dfv_consultar` para a Mari (n8n) | `n8n/RPC_dfv_consultar_031126_2130.md` |

Telas do menu que ainda não existem aparecem desabilitadas ("em breve"). Mari, n8n, importação dos relatórios da Nio e Meta Ads vêm nos próximos prompts.

## Travas que o banco garante (trigger `vendas_antes_status`)

- Sair de "Qualificado" (status 1 a 5) exige **nº do pedido do APP NiO PAP** e **biometria aprovada** — senão `RAISE`, que o front mostra como toast.
- Entrar em "Aguardando instalação" grava `agendamento_registrado_em = now()` (indicador de 4 h).
- "Saída" exige motivo.
- Toda mudança de status, todo agendamento e todo contato vira linha em `eventos_venda`.

## Comissão e vencimento (calculados no banco)

- `recalcular_comissao(venda_id)` roda por trigger quando mudam plano, segmento, forma, status/`vendido_em` ou os adicionais:
  `comissao_prevista` = nominal + adicionais + transição + NMEI. O **M-10** fica só em `bonus_m10_potencial` e nunca entra na prevista.
- `vendas_calcula_vencimento`: boleto/débito vence 25 dias após `instalado_em` (dia recorrente = dia do 1º vencimento, ou 26 se instalou em 29–31);
  cartão cobra no dia da instalação. Vale também quando o OSAB grava `instalado_em`. O vencimento não é digitado.
- Mudou a tabela da Nio: nova migration (planos com nova `vigencia_inicio`), nunca edição à mão.

## Importação do OSAB

Configurações › Importação: o arquivo é reconhecido pelas colunas (`PEDIDO`, `SITUACAO`, `fg_venda_valida`, `DATA_ABERTURA`, `DT_REF`),
lido no navegador (SheetJS), mostra a prévia e só então grava `importacoes` + `nio_osab` (lotes de 500) e chama `aplicar_osab()`.
A regra da prévia (`docs/assets/osab.js`) e a do banco (`aplicar_osab`) são a mesma — mudou uma, muda a outra.
O OSAB só avança status (2 → 3 → 4 em concluído/válida; 1–2 → saída em cancelamento) e nunca apaga campo com vazio.
Pedido repetido no arquivo: fica a ordem com `DATA_ABERTURA` mais recente.

## Base DFV (viabilidade)

A Nio entrega um CSV por município (`;`, UTF-8 com BOM, só endereços **viáveis**). **Nunca entra no repo** (`*.csv` no `.gitignore`):
vai para o Supabase e só lá fica. Fora da base = sem viabilidade hoje.

- Carga (hoje só pelo CLI; a tela faz a prévia):
  `python -I supabase/scripts/dfv_carga.py <arquivo.csv> <pasta FORA do repo> <uuid do admin>` e depois
  `npx.cmd supabase db query --remote --yes -f <cada .sql, em ordem>` — o `99_aplicar.sql` chama `aplicar_dfv`,
  que troca a partição inteira do município (nunca merge) e grava o resumo em `importacoes` (tipo `dfv_hp`).
- `dfv_consultar(cep, numero, complemento)` → `viavel` · `viavel_predio` (+ `opcoes`) · `endereco_ocupado` · `sem_porta_livre` · `nao_encontrado` · `precisa_numero`.
  O trigger `vendas_antes_cobertura` usa a mesma função quando uma venda em Qualificado ganha CEP + número; o seletor manual continua (`dfv_origem = 'manual'`).

## Rodar local

1. Copie `docs/config.example.js` para `docs/config.js` e preencha a URL e a chave **anon** do Supabase Nio.
2. Sirva a pasta `docs/` em qualquer servidor estático, por exemplo:

   ```bash
   npx --yes http-server docs -p 5500 -c-1
   ```

3. Abra `http://localhost:5500`. No Supabase, em Authentication › URL Configuration, inclua `http://localhost:5500` e a URL do Pages.

## Banco

```bash
npx supabase login
npx supabase link --project-ref <ref-do-projeto-nio>
npx supabase db push
```

Depois, no SQL editor: criar o usuário do Ricardo em Authentication › Users (Auto Confirm) e rodar `supabase/seed/usuarios_seed.sql`
(planos, área e bônus vêm da migration `0005`). **Nada à mão no painel sem migration correspondente.**

## Publicar (GitHub Pages)

O Pages publica `docs/` pelo workflow `.github/workflows/pages.yml` (Settings › Pages › Source: **GitHub Actions**).
O `docs/config.js` não entra no git: o workflow gera a partir de

- repo variable `SUPABASE_NIO_URL`
- repo secret `SUPABASE_NIO_ANON`

A cada publicação, **bumpar o `CACHE` em `docs/sw.js`** (`niogen-DDMMAA-N`) **e o `?v=DDMMAA-N`** dos `config.js`, `app.js`, `sidebar.js` e `app.css` nos HTML
(o Pages manda o navegador guardar cada arquivo por 10 min; sem o `?v` uma tela nova pode rodar com um script velho). A prova de que pegou é abrir a tela publicada.

## Segredos

Nenhum no repo. A service role do Supabase vive só no gerenciador de senhas e no n8n. Antes de cada push:

```bash
git grep -iE "service[_]role"
```

```bash
git grep -E "ey[J]"
```

(os dois têm que voltar vazios; os colchetes evitam que o próprio README apareça na busca).
