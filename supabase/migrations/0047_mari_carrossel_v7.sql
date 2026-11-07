-- NIOGEN | supabase/migrations/0047_mari_carrossel_v7.sql | 06/11/2026 — Claude Code (prompts 26 + 27 unificados, Mari v7)
-- Resumo:
--   1. config_mari_carrossel: os 4 cartões do carrossel de ofertas (Varejo Regular), com imagem, texto do cartão, texto do
--      "Mais detalhes" e os títulos dos botões — textos COPIADOS LITERALMENTE de docs/MARI_carrossel_botoes_spec_061126_1830.md
--      (decisão do Ricardo 06/11 18h28). Trocar texto/imagem/preço = mudar a spec, esta tabela e o Diário no mesmo passo.
--      Plano B dos títulos (aprovado 06/11 18h42) = UPDATE de titulo_quero/titulo_detalhes, sem código novo.
--   2. config_mari_textos: corpo do carrossel e do pagamento (chave → texto).
--   3. vendas_referencia_da_mari: a venda que a Mari cria herda o ponto de referência coletado (dados.referencia) —
--      o portal PAP exige na etapa 2 (prompt 27 A5). Não mexe no mari_handoff.
-- Leitura admin/backoffice; escrita admin; o n8n lê com a service role.

-- ---------------------------------------------------------------- 1. carrossel
create table if not exists public.config_mari_carrossel (
  id              serial primary key,
  ordem           int  not null unique check (ordem between 0 and 9),
  plano_codigo    text not null references public.config_planos(codigo),
  imagem_url      text not null check (imagem_url ~ '^https://'),
  texto_card      text not null check (char_length(texto_card) <= 160),
  texto_detalhes  text not null,
  titulo_quero    text not null default 'Eu quero!'     check (char_length(titulo_quero) <= 20),
  titulo_detalhes text not null default 'Mais detalhes' check (char_length(titulo_detalhes) <= 20),
  ativo           boolean not null default true,
  atualizado_em   timestamptz not null default now()
);
comment on table public.config_mari_carrossel is
  'Carrossel de ofertas da Mari (só Varejo em cidade Regular). Textos exatos da spec 06/11 18h30. O n8n confere os preços do texto contra config_planos antes de enviar.';

create table if not exists public.config_mari_textos (
  chave         text primary key,
  texto         text not null,
  atualizado_em timestamptz not null default now()
);
comment on table public.config_mari_textos is 'Textos fixos das mensagens interativas da Mari (corpo do carrossel, do pagamento…).';

alter table public.config_mari_carrossel enable row level security;
alter table public.config_mari_textos    enable row level security;
drop policy if exists config_mari_carrossel_ler on public.config_mari_carrossel;
drop policy if exists config_mari_carrossel_admin on public.config_mari_carrossel;
drop policy if exists config_mari_textos_ler on public.config_mari_textos;
drop policy if exists config_mari_textos_admin on public.config_mari_textos;
create policy config_mari_carrossel_ler on public.config_mari_carrossel for select to authenticated
  using (public.meu_perfil() in ('admin', 'backoffice'));
create policy config_mari_carrossel_admin on public.config_mari_carrossel for all to authenticated
  using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');
create policy config_mari_textos_ler on public.config_mari_textos for select to authenticated
  using (public.meu_perfil() in ('admin', 'backoffice'));
create policy config_mari_textos_admin on public.config_mari_textos for all to authenticated
  using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');
grant select, insert, update, delete on public.config_mari_carrossel, public.config_mari_textos to authenticated;
grant usage, select on sequence public.config_mari_carrossel_id_seq to authenticated;

-- Textos LITERAIS da spec (emojis, espaços e quebras inclusive — o espaço no fim de "R$ 110,00 " e o duplo em "Wi-Fi 5.  E" são da spec).
insert into public.config_mari_carrossel (ordem, plano_codigo, imagem_url, texto_card, texto_detalhes) values
(0, 'V-REG-FIBRA', 'https://ricardocandrade-eng.github.io/niogen/assets/mari/carrossel/MARI_carrossel_fibra_061126_1830.jpg',
$t$Plano Nio Fibra - com velocidade de⚡ 600 Mega

Por R$ 110,00 ou R$ 95,00 no cartão 🛜 Roteador Wi-Fi 5$t$,
$t$Plano Nio Fibra por R$ 110,00
No cartão de crédito: R$ 95,00

600 Mega de velocidade com roteador Wi-Fi 5.  E o valor do seu plano não muda até janeiro de 2030!$t$),
(1, 'V-REG-ESS', 'https://ricardocandrade-eng.github.io/niogen/assets/mari/carrossel/MARI_carrossel_essencial_061126_1830.jpg',
$t$Plano Nio Essencial - com velocidade de⚡ 800 Mega

Por R$ 140,00 ou R$ 125,00 no cartão 🛜 Roteador Wi-Fi 6 - 📶 1 chip 5G de 10GB$t$,
$t$Nio Essencial⚡

WhatsApp - Mensagens de texto e áudio e ligações de áudio e vídeo sem gastar sua franquia.

Chamadas - Ligações ilimitadas para qualquer operadora do Brasil.

SMS - Mensagens de texto ilimitadas, o mês inteiro.

Waze - Navegação sem consumir sua franquia, nos planos Nio Super e Nio Ultra.$t$),
(2, 'V-REG-SUP', 'https://ricardocandrade-eng.github.io/niogen/assets/mari/carrossel/MARI_carrossel_super_061126_1830.jpg',
$t$Plano Nio Super - com velocidade de⚡ 1 Giga

Por R$ 170,00 ou R$ 155,00 no cartão 🛜 Roteador Wi-Fi 6 - 📶1 chip 5G de 20GB - 🖥️Globoplay por 12 meses$t$,
$t$Nio Super⚡

WhatsApp - Mensagens de texto e áudio e ligações de áudio e vídeo sem gastar sua franquia.

Chamadas - Ligações ilimitadas para qualquer operadora do Brasil.

SMS - Mensagens de texto ilimitadas, o mês inteiro.

Waze - Navegação sem consumir sua franquia, nos planos Nio Super e Nio Ultra.$t$),
(3, 'V-REG-ULT', 'https://ricardocandrade-eng.github.io/niogen/assets/mari/carrossel/MARI_carrossel_ultra_061126_1830.jpg',
$t$Plano Nio Ultra - com velocidade de⚡ 1 Giga

Por R$ 200,00 ou R$ 185,00 no cartão 🛜 Ponto extra Mesh Wi-Fi 6 📶2 chip 5G 20GB 🖥️Globoplay 12 meses$t$,
$t$Nio Ultra⚡

WhatsApp - Mensagens de texto e áudio e ligações de áudio e vídeo sem gastar sua franquia.

Chamadas - Ligações ilimitadas para qualquer operadora do Brasil.

SMS - Mensagens de texto ilimitadas, o mês inteiro.

Waze - Navegação sem consumir sua franquia, nos planos Nio Super e Nio Ultra.$t$)
on conflict (ordem) do nothing;

insert into public.config_mari_textos (chave, texto) values
('carrossel_corpo', $t$Essas são as ofertas especiais Nio! 🚀 Garanta já!

Deslize para ver todas as ofertas$t$),
-- {de} e {por} = preco e preco_cartao do plano escolhido (config_planos), com vírgula: "200,00".
('pagamento_corpo', $t$Como você quer pagar?

💳 Pagando no cartão de crédito, seu plano tem desconto:

De: R$ {de}/mês
Por: R$ {por}/mês$t$),
-- Cidade BTU (sem desconto no cartão): os botões vêm sem o bloco De/Por (spec §6).
('pagamento_corpo_sem_desconto', $t$Como você quer pagar?$t$)
on conflict (chave) do nothing;

-- Um objeto só para o n8n (nó "4c · Supabase interativo"): {cartoes: [...], textos: {chave: texto}}. Só service_role.
create or replace function public.mari_config_interativo()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'cartoes', coalesce((select jsonb_agg(jsonb_build_object(
        'ordem', k.ordem, 'plano_codigo', k.plano_codigo, 'imagem_url', k.imagem_url, 'texto_card', k.texto_card,
        'texto_detalhes', k.texto_detalhes, 'titulo_quero', k.titulo_quero, 'titulo_detalhes', k.titulo_detalhes,
        'preco', p.preco, 'preco_cartao', p.preco_cartao, 'nome', p.nome, 'nome_curto', p.nome_curto) order by k.ordem)
      from public.config_mari_carrossel k join public.config_planos p on p.codigo = k.plano_codigo
      where k.ativo), '[]'::jsonb),
    'textos', coalesce((select jsonb_object_agg(chave, texto) from public.config_mari_textos), '{}'::jsonb));
$$;
revoke all on function public.mari_config_interativo() from public, anon, authenticated;
grant execute on function public.mari_config_interativo() to service_role;

-- ---------------------------------------------------------------- 3. referência da Mari → venda
create or replace function public.vendas_referencia_da_mari()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref text;
begin
  if coalesce(btrim(new.ponto_referencia), '') = '' and coalesce(new.origem_ref, '') ~ '^mari:[0-9a-f-]{36}$' then
    select nullif(btrim(c.dados ->> 'referencia'), '') into v_ref
      from public.mari_conversas c
     where c.id = substring(new.origem_ref from 6)::uuid;
    if v_ref is not null then
      new.ponto_referencia := left(v_ref, 200);
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.vendas_referencia_da_mari() from public, anon, authenticated;

drop trigger if exists vendas_referencia_da_mari on public.vendas;
create trigger vendas_referencia_da_mari
  before insert on public.vendas
  for each row execute function public.vendas_referencia_da_mari();
