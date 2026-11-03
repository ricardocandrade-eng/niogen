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
| Seed de EXEMPLO de planos e área (apagar quando a tabela real chegar) | `supabase/seed/config_exemplo_seed.sql` |
| Login | `docs/index.html` |
| Funil 0→5 + Saída | `docs/funil.html` |
| Instalações por tempo | `docs/instalacoes.html` |
| Vendas + venda de rua | `docs/vendas.html` |
| Detalhe da venda | `docs/venda.html?id=` |

Telas do menu que ainda não existem aparecem desabilitadas ("em breve"). Mari, n8n, importação dos relatórios da Nio e Meta Ads vêm nos próximos prompts.

## Travas que o banco garante (trigger `vendas_antes_status`)

- Sair de "Qualificado" (status 1 a 5) exige **nº do pedido do APP NiO PAP** e **biometria aprovada** — senão `RAISE`, que o front mostra como toast.
- Entrar em "Aguardando instalação" grava `agendamento_registrado_em = now()` (indicador de 4 h).
- "Saída" exige motivo.
- Toda mudança de status, todo agendamento e todo contato vira linha em `eventos_venda`.

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
e, enquanto a tabela real não chega, `supabase/seed/config_exemplo_seed.sql`. **Nada à mão no painel sem migration correspondente.**

## Publicar (GitHub Pages)

O Pages publica `docs/` pelo workflow `.github/workflows/pages.yml` (Settings › Pages › Source: **GitHub Actions**).
O `docs/config.js` não entra no git: o workflow gera a partir de

- repo variable `SUPABASE_NIO_URL`
- repo secret `SUPABASE_NIO_ANON`

A cada publicação, **bumpar o `CACHE` em `docs/sw.js`** (`niogen-DDMMAA-N`). A prova de que pegou é abrir a tela publicada.

## Segredos

Nenhum no repo. A service role do Supabase vive só no gerenciador de senhas e no n8n. Antes de cada push:

```bash
git grep -iE "service[_]role"
```

```bash
git grep -E "ey[J]"
```

(os dois têm que voltar vazios; os colchetes evitam que o próprio README apareça na busca).
