<!-- NIOGEN | meta/README.md | 05/11/2026 — Claude Code, prompt 20 — como rodar o script da campanha 1 (sem segredo) -->

# Meta Ads Nio — scripts da API de Marketing

O conector do Meta no Cowork não cria campanha nem conjunto, e o Ricardo não usa o Gerenciador. A estrutura
nasce aqui, pela API, **sempre em PAUSED**. Quem ativa é o Ricardo (ou o Cowork pelo conector, depois de revisar).

## `campanha1_jf.py` — campanha 1 de Juiz de Fora

Plano: `docs/META_ADS_campanha1_JF_051126_2230.md` (pasta do Drive). Cria, se ainda não existir (procura pelo nome):

| Objeto | Nome | Detalhe |
|---|---|---|
| 8 imagens | `NIO_JF_{M1,G1,M2,G2}_*_{1x1,9x16}_*.png` | lidas da pasta do Drive `criativos_nov26/` — **nunca copiadas para o repo** |
| Campanha | `NIO_JF_C1_MSG_nov26` | `OUTCOME_ENGAGEMENT` · CBO R$ 70/dia · `LOWEST_COST_WITHOUT_CAP` |
| Conjunto A | `CJ_A_altopadrao` | WhatsApp · `CONVERSATIONS` · pino -21.765/-43.348, raio 2 km · 25–65 |
| Conjunto B | `CJ_B_medio` | pino -21.735/-43.350, raio 1,5 km (2 km se a API recusar) · 25–65 |
| 4 criativos | `CR_AD_*_v3` | 1x1 no feed + 9x16 em stories/reels; CTA `WHATSAPP_MESSAGE`; mensagem pronta; melhorias automáticas que a API aceita desligar (animação, tradução de texto, legenda, cartão de perfil) desligadas; Instagram = **@mari.nio.internet** |
| 8 anúncios | `AD_M1_preco2030` · `AD_G1_preco2030` · `AD_M2_troca` · `AD_G2_cobertura` em cada conjunto | |

Quando a API recusa uma variante (raio, número do WhatsApp no `promoted_object`, 9x16, mensagem pronta,
desligar melhorias automáticas), o script tenta a próxima e **anota** o que ficou em `anotacoes` no JSON de saída.

### Como rodar

```bash
python meta/campanha1_jf.py --dry-run          # sem token: só o plano; com token: + o que já existe
python meta/campanha1_jf.py --descobrir        # só leitura: conta, páginas promovíveis e o WhatsApp de cada uma
python meta/campanha1_jf.py --page-id <ID>     # cria o que falta, tudo PAUSED (ID confirmado com o Ricardo)
```

Saída: `meta/campanha1_jf_ids.json` (IDs de campanha, conjuntos, criativos, anúncios e hashes das imagens — não
são segredo, vai versionado). O script para se a página não tiver o WhatsApp da Mari (+55 31 2888-1265) e
termina conferindo que tudo ficou `PAUSED`.

### Pré-requisitos (o que travou em 05–06/11 e como ficou)

| Trava | Como ficou |
|---|---|
| Token só com `ads_*` não lê nem anuncia pela página | token do `Nio_API` com `ads_management`, `ads_read`, `pages_show_list`, `pages_read_engagement`, `pages_manage_ads` |
| Página precisa estar atribuída ao `Nio_API` | página **Mari Nio Internet** (antes "Nio Internet · Dharma Telecom") `1421228191072269`, atribuída com tarefa de anúncios |
| WhatsApp da Mari ligado à página | feito no BM: Contas do WhatsApp → Perfil do telefone (2888-1265) → Facebook → Gerenciar. O campo `whatsapp_number` da página **não** mostra esse vínculo; a prova é o conjunto aceitar `whatsapp_phone_number` |
| "criativo criado por app em modo de desenvolvimento" (subcode 1885183) | app **NIOGEN publicado** (modo ativo), com a política em `docs/privacidade.html` |
| "conta do Instagram ausente" (subcode 1772103) no anúncio | `instagram_user_id` no criativo: primeiro a conta "da página" `17841423276547518`; desde 06/11 o **@mari.nio.internet** `17841411489935097` (BM → Perfis do Instagram → Conectar ativos: página + CA; Atribuir pessoas: `Nio_API`). A Central de Contas recusou o @ novo ("não se qualifica") — pelo BM funcionou |
| `degrees_of_freedom_spec`: só aceita as chaves que a API lista no erro | ver `OPT_OUT` no script |
| `?ids=` descontinuado | conferência de status objeto a objeto |
| Regra do 1x1 só com `publisher_platforms` não casa com nenhum feed (prévia "0 regras para MOBILE_FEED_STANDARD") | posições listadas explicitamente; criativo trocado nos anúncios existentes (`_v2`). Audience Network outstream é só vídeo e fica sem regra |
| Limite de chamadas da conta (code 17/2446079) depois de muitas prévias | esperar ~5 min |

### Token

`META_ACCESS_TOKEN_NIO` (app **NIOGEN**, system user `Nio_API`, `ads_read` + `ads_management`). O script lê, nessa
ordem: variável de ambiente → variável de usuário do Windows → `.env` na raiz do clone (no `.gitignore`).
O token nunca é impresso nem gravado. Para gravar como variável de usuário sem passar pelo chat:

```powershell
$s = Read-Host 'Token Meta Nio' -AsSecureString; [Environment]::SetEnvironmentVariable('META_ACCESS_TOKEN_NIO', [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)), 'User')
```

### O que este script nunca faz

Ativar nada · criar pixel/dataset ou público personalizado · usar dado de cliente (Nio ou Vero) · usar token,
página, app ou número da Vero.

## `publicar_credibilidade.py` — posts e stories de credibilidade de JF (prompt 21)

Publica os 9 posts no feed do Instagram **@mari.nio.internet** (`17841411489935097`) e da página
**Mari Nio Internet** (antes "Nio Internet · Dharma Telecom") (`1421228191072269`), na ordem 09 → 01 (o 01 fica no topo da grade), e os
4 stories no Instagram (clientes, dúvidas, cobertura, planos). Stories da página só com `--fb-stories`.

| Arquivo | O que é |
|---|---|
| `meta/credibilidade_nov26.json` | `arquivo`, `legenda`, `ordem` — legenda **literal** de `credibilidade_nov26/textos_credibilidade_061126_0915.md` (Drive). Não reescrever aqui: muda lá e regera |
| `docs/midia/credibilidade_nov26/*.jpg` | as 13 peças com URL pública no Pages. **JPEG**, não PNG: a API do Instagram só aceita JPEG por `image_url` |
| `meta/credibilidade_ids.json` | id do container, da mídia do IG e do post da página, com data, hora e permalink. O que tem id é pulado |

```bash
python meta/publicar_credibilidade.py              # = --dry-run: URLs (200 image/jpeg?), escopos e a lista
python meta/publicar_credibilidade.py --conferir   # só leitura: legenda publicada × JSON nos dois feeds
python meta/publicar_credibilidade.py --publicar   # só com o OK do Ricardo na sessão
```

- Instagram: `POST /{ig}/media` → espera `status_code = FINISHED` → `POST /{ig}/media_publish`; 60 s entre posts do feed.
- Página: `POST /{página}/photos` (`url`, `message`, `published=true`) com o token da página, tirado em memória.
- Idempotência dupla: id no `credibilidade_ids.json` **ou** legenda idêntica já publicada (adota o id) → não publica de novo.
- Erro em um item: para e mostra. Exceção: stories da página recusados por permissão são registrados e o resto segue.
- A API não põe adesivo de link nem cria destaque, e o story some em 24 h: **o Ricardo monta os destaques no app logo depois**.
- Recusa legenda com "sem fidelidade", desconto, Dharma, Vero, CNPJ, data de instalação ou "grátis" fora de
  "Instalação grátis com 12 meses de permanência".

**Escopos do token** (`META_ACCESS_TOKEN_NIO`, `Nio_API`, app NIOGEN): além dos `ads_*`, `pages_show_list`,
`pages_read_engagement` e `pages_manage_ads`, precisa de **`instagram_basic`, `instagram_content_publish` e
`pages_manage_posts`**. O script confere por `GET /me/permissions` (o `debug_token` recusa token de system user
sem token de app) e não publica se faltar algum.
