-- NIOGEN | supabase/migrations/0317_parceiro_pap_sem_dharma_contato_planos.sql | 19/11/2026 — Claude Code (Opus 5.5)
-- Ajustes do Programa Parceiro PAP (Ricardo, 19/11/2026):
--  (1) "Retirar qualquer menção a Dharma nas telas": as mensagens que o banco devolve ao Pocket (erros e avisos de 8 funções
--      parceiro_*) trocam "a Dharma" por "a gente / o nosso time / o nosso WhatsApp". Só texto: a função é recriada a partir da
--      definição atual (pg_get_functiondef) com replace — nenhuma lógica muda. O id interno 'dharma' (tenant, regra 15) fica.
--  (2) "O número que vai falar com eles e enviar o link de cadastro é o +55 32 92003-5815": config_regras.parceiro_contato_whatsapp
--      (o botão "Falar com a gente" do Pocket já lia esta chave; sem ela caía no resumo_destino_whatsapp, o celular do Ricardo).
--      Nova parceiro_contato(), liberada para anon: o Pocket mostra o número na entrada e no fim do "Quero ser parceiro".
--  (3) "Existem planos demais": a tabela de comissão do parceiro tinha 23 linhas, 8 delas cópias "sem fidelidade" (V-NFID-*, V-O50N-*)
--      com o mesmo valor do plano com fidelidade — e o parceiro nem escolhe essas variantes no Pocket (parceiro_planos só traz
--      regular/oferta50). Agora a comissão é por plano de verdade (15 linhas: Varejo 4 + Varejo BTU 4 + Empresas 4 + Empresas BTU 3);
--      a venda sem fidelidade paga a comissão do plano irmão com fidelidade. config_planos não muda (a variante continua existindo
--      para a Mari, a ficha e a conciliação).
-- Tabela individualizada: parceiro_comissao(parceiro_id, plano_id) — linha com parceiro_id = o valor DAQUELE parceiro; nulo = padrão.
-- parceiro_comissao_valor() continua: o do parceiro, senão o padrão.
-- Regra 20: (1)(2) nenhum estado de lead novo; (3) nenhuma gravação de status; (4) a comissão segue uma fonte só (parceiro_comissao);
-- (5) conferência: sem número novo — o aviso "instalada sem comissão" de parceiros.html continua valendo. Desempenho: sem impacto.
begin;

-- (2) o WhatsApp do programa
update public.config_regras set valor = to_jsonb('5532920035815'::text),
       descricao = 'Programa Parceiro PAP: WhatsApp que fala com os parceiros e manda o link de acesso (55+DDD+número). Aparece no Pocket (entrada, cadastro, "Falar com a gente"). Ricardo, 19/11/2026.',
       atualizado_em = now()
 where chave = 'parceiro_contato_whatsapp';
insert into public.config_regras (chave, valor, descricao)
select 'parceiro_contato_whatsapp', to_jsonb('5532920035815'::text),
       'Programa Parceiro PAP: WhatsApp que fala com os parceiros e manda o link de acesso (55+DDD+número). Aparece no Pocket (entrada, cadastro, "Falar com a gente"). Ricardo, 19/11/2026.'
 where not exists (select 1 from public.config_regras where chave = 'parceiro_contato_whatsapp');

create or replace function public.parceiro_contato()
returns text language sql stable security definer set search_path = public as $$
  select public.tel_norm(public.config_regra('parceiro_contato_whatsapp', null) #>> '{}')
$$;
comment on function public.parceiro_contato() is 'WhatsApp do Programa Parceiro PAP (config_regras.parceiro_contato_whatsapp). Público: aparece na tela de entrada do Pocket.';
revoke execute on function public.parceiro_contato() from public;
grant execute on function public.parceiro_contato() to anon, authenticated;

-- (1) textos sem "Dharma" nas funções do Pocket (a ordem importa: as frases mais longas primeiro)
do $$
declare
  f   record;
  def text;
  novo text;
begin
  for f in
    select p.oid, p.proname from pg_proc p join pg_namespace s on s.oid = p.pronamespace
     where s.nspname = 'public' and p.proname in ('parceiro_ativo_ou_erro', 'parceiro_cadastrar', 'parceiro_consultar_endereco',
             'parceiro_enviar_venda', 'parceiro_minhas_vendas', 'parceiro_motivo_texto', 'parceiro_resumo')
  loop
    def := pg_get_functiondef(f.oid);
    novo := def;
    novo := replace(novo, 'Peça um novo link à Dharma.', 'Peça um novo link pelo nosso WhatsApp.');
    novo := replace(novo, 'A Dharma vai te chamar no WhatsApp.', 'A gente vai te chamar no WhatsApp.');
    novo := replace(novo, 'fale com a Dharma.', 'fale com a gente.');
    novo := replace(novo, 'Fale com a Dharma.', 'Fale com a gente.');
    novo := replace(novo, 'A Dharma já está atendendo este endereço.', 'Este endereço já está em atendimento com a gente.');
    novo := replace(novo, 'em atendimento com a Dharma.', 'em atendimento com a gente.');
    novo := replace(novo, 'atender a ligação da Dharma.', 'atender a nossa ligação.');
    if novo ~ 'Dharma' then
      raise exception '0317: ainda sobra "Dharma" em %', f.proname;
    end if;
    if novo <> def then
      execute novo;
    end if;
  end loop;
end;
$$;

-- (3) comissão por plano de verdade: a variante sem fidelidade usa o plano irmão com fidelidade
create or replace function public.parceiro_comissao_plano_base(p_plano bigint)
returns bigint language sql stable set search_path = public as $$
  select coalesce(
    (select b.id from public.config_planos pl
       join public.config_planos b
         on b.codigo = case pl.variante when 'nfid' then replace(pl.codigo, 'V-NFID-', 'V-REG-')
                                        when 'oferta50_nfid' then replace(pl.codigo, 'V-O50N-', 'V-O50-') end
      where pl.id = p_plano),
    p_plano)
$$;
comment on function public.parceiro_comissao_plano_base(bigint) is
  'Plano que define a comissão do parceiro: sem fidelidade (V-NFID-*, V-O50N-*) → o irmão com fidelidade (V-REG-*, V-O50-*); o resto → ele mesmo.';
revoke execute on function public.parceiro_comissao_plano_base(bigint) from public, anon;
grant execute on function public.parceiro_comissao_plano_base(bigint) to authenticated;

create or replace function public.parceiro_comissao_valor(p_parceiro uuid, p_plano bigint)
returns numeric language sql stable set search_path = public as $$
  select coalesce(
    (select valor from public.parceiro_comissao where parceiro_id = p_parceiro and plano_id = public.parceiro_comissao_plano_base(p_plano)),
    (select valor from public.parceiro_comissao where parceiro_id is null      and plano_id = public.parceiro_comissao_plano_base(p_plano)))
$$;

-- As 8 linhas sem fidelidade saem da tabela (hoje só existem no padrão, com o mesmo valor do irmão). Valor próprio de algum parceiro
-- numa variante sem fidelidade (nenhum hoje) passa para o irmão antes de sair, se o irmão ainda não tiver.
insert into public.parceiro_comissao (parceiro_id, plano_id, valor)
select c.parceiro_id, public.parceiro_comissao_plano_base(c.plano_id), c.valor
  from public.parceiro_comissao c join public.config_planos pl on pl.id = c.plano_id
 where pl.variante in ('nfid', 'oferta50_nfid') and c.parceiro_id is not null
   and not exists (select 1 from public.parceiro_comissao x
                    where x.parceiro_id = c.parceiro_id and x.plano_id = public.parceiro_comissao_plano_base(c.plano_id));
delete from public.parceiro_comissao c using public.config_planos pl
 where pl.id = c.plano_id and pl.variante in ('nfid', 'oferta50_nfid');

commit;
