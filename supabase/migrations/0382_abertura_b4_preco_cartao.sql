-- NIOGEN | supabase/migrations/0382_abertura_b4_preco_cartao.sql | 24/11/2026 — Claude Code / Opus 5.5
-- Prompt docs/Prompt_mari_abertura_preco_cartao_241126_1645.md (Cowork) — Ricardo, 24/11 16h40: "Estou de acordo"; nesta sessão,
-- "Motor + --sem-portao". Por quê: os criativos da C3 anunciam R$ 95 (cartão) e a abertura B4 dizia só "a partir de R$ 110" — quem
-- clicava via o preço subir na 1ª mensagem.
-- O que muda (só config_mari_textos; o 5b, publicado junto, escolhe o corpo pelo cluster do conjunto do anúncio:
-- abertura_corpo_b4_<cluster>, senão abertura_corpo_b4, e preenche {preco_cartao_entrada} do mesmo plano de entrada em config_planos):
--   · abertura_corpo_b4_regular: "a partir de R$ {preco_entrada}, ou R$ {preco_cartao_entrada} no cartão de crédito" (Regular: 110/95).
--   · abertura_corpo_b4_btu: SEM a frase do cartão — na Oferta 50 % das 15 cidades BTU não existe desconto no cartão (base §3b).
--     (Hoje nenhum conjunto com preço é BTU; a chave existe para quando houver.) Plano sem preço no cartão com texto que pede o
--     cartão cai, no código, no corpo geral — nunca sai desconto de cartão em cidade BTU.
--   · abertura_corpo_b4 (geral, sem cartão) e sem referral (sem preço): não mudam.
-- Volta sem deploy: apagar abertura_corpo_b4_regular (o corpo geral, sem cartão, volta a valer). Texto anterior em uso:
--   'Aqui é a Mari, da Nio 😊\n\nA fibra de 600 Mega sai a partir de R$ {preco_entrada}, e o valor que você fechar agora fica travado até
--    janeiro de 2030, sem reajuste todo ano.'
-- Regra 20: só texto em config — nenhuma situação, estado ou porta; consequência e conferência inalteradas (v_mari_abertura mede).
-- Regra 15: o valor sai de config_planos, nunca do texto. Regra 19: sem tela e sem chamada nova.
-- Medir com a B4 em 01/12: % que manda CEP/rua e venda com OS (não % de toque).

begin;

do $$
begin
  if (select texto from public.config_mari_textos where chave = 'abertura_versao') is distinct from 'b4_241126' then
    raise exception 'abertura_versao não é b4_241126 — conferir antes';
  end if;
end $$;

insert into public.config_mari_textos (chave, texto) values
('abertura_corpo_b4_regular', $t$Aqui é a Mari, da Nio 😊

A fibra de 600 Mega sai a partir de R$ {preco_entrada}, ou R$ {preco_cartao_entrada} no cartão de crédito, e o valor que você fechar agora fica travado até janeiro de 2030, sem reajuste todo ano.$t$),
('abertura_corpo_b4_btu', $t$Aqui é a Mari, da Nio 😊

A fibra de 600 Mega sai a partir de R$ {preco_entrada}, e o valor que você fechar agora fica travado até janeiro de 2030, sem reajuste todo ano.$t$)
on conflict (chave) do update set texto = excluded.texto;

do $$
begin
  if (select count(*) from public.config_mari_textos
       where (chave = 'abertura_corpo_b4_regular' and texto like '%{preco_cartao_entrada} no cartão de crédito%')
          or (chave = 'abertura_corpo_b4_btu' and texto not like '%cartão%')) <> 2 then
    raise exception '0382: textos do preço da abertura não ficaram como esperado';
  end if;
end $$;

commit;
