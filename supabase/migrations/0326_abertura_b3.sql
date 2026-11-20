-- NIOGEN | supabase/migrations/0326_abertura_b3.sql | 19/11/2026 — Claude Code / Opus 5.5
-- Prompt docs/Prompt_abertura_ancorada_e_flow_171126_1620.md, ETAPA 1, na forma enxuta decidida pelo Ricardo em 19/11
-- ("Concordo com a questão do preço" · "Sim, pode seguir nessa ordem"): abertura B3 SEM preço e SEM A/B.
-- Por quê (linha de base, 14 d, meta_ads, 145 aberturas B2): quem NÃO tocou botão nenhum = 46 (só 20 deram CEP, 18 sumiram);
-- o "🔒 Preço até 2030" era rótulo sem argumento (9 toques). Quem tocou "Ver minha rua" deu CEP 43/45; "Ver os planos" (menu
-- antigo, até 16/11) deu CEP 26/28 e 7 vendas — o 2º melhor botão, e saiu do menu só porque não mostrava plano sem a cidade.
-- O que muda (só textos — o 5 · Motor já lê tudo de config_mari_textos a cada mensagem; nada no mari_principal):
--   · abertura_corpo: o argumento do 2030 vai no corpo (todo mundo lê, toque ou não). Sem preço: o preço depende da cidade
--     (cluster btu × regular) e a abertura sai antes do CEP — regra 1, nada fora da tabela daquela cidade.
--   · menu: 📍 Ver minha rua · 💰 Ver os planos · 🏠 Sou cliente Nio (títulos existentes, ≤ 20 caracteres; quem tem o menu
--     antigo na tela segue reconhecido — o 5b casa pelo título de todos os botões, não só dos do menu).
--   · abertura_resp_planos: não repete o 2030 nem a faixa (já estão no corpo), pede o CEP.
--   · abertura_fallback (botões não saíram): mesmo argumento.
--   · abertura_versao = 'b3_191126': rótulo gravado em dados.abertura e mari_turnos.tags — compara antes × depois.
-- Não muda: resposta do "Ver minha rua", "Sou cliente Nio" (Saída ja_cliente_nio, 0234), lembrete L15, cadência, formato botões.
-- Volta sem deploy: abertura_versao = 'b2_081126', abertura_botoes = 'trava2030,rua,cliente' e os textos abaixo (antes = comentário).
-- Regra 20: (1) situação/vez/prazo — sem estado novo (a conversa segue em abertura, vez da Mari, L15/F1 de sempre) · (2) porta
-- única — só config, nenhum status gravado · (3) consequência é tabela — inalterada · (4) fonte única — texto só em
-- config_mari_textos · (5) conferência — não cria estado nem número novo; v_mari_abertura já separa por versão.
-- Desempenho: sem impacto (nenhuma tela nem consulta muda). Medir em 7 dias: das aberturas b3, % sem toque e % que dá CEP,
-- contra a B2 (46/145 sem toque; 111/145 com CEP).

begin;

do $$
begin
  if (select texto from public.config_mari_textos where chave = 'abertura_versao') is distinct from 'b2_081126' then
    raise exception 'abertura_versao não é b2_081126 — alguém mudou a abertura; conferir antes';
  end if;
end $$;

-- antes: 'Oi, {nome}, tudo bem? 💚\n\nAqui é a Mari, da Nio. Fiquei feliz com sua mensagem!\n\nTe mostro rapidinho, sem compromisso nenhum. O que você prefere ver primeiro?'
update public.config_mari_textos set texto = $t$Oi, {nome}, tudo bem? 💚

Aqui é a Mari, da Nio. Os planos de fibra vão de 600 Mega a 1 Giga, e o valor que você fechar agora fica travado até janeiro de 2030, sem reajuste todo ano.

Como prefere começar?$t$ where chave = 'abertura_corpo';

-- antes: 'Oi, {nome}, tudo bem? 💚\n\nAqui é a Mari, da Nio. Fiquei feliz com sua mensagem!\n\nMe manda seu CEP (ou o nome da rua e o bairro) que eu já te mostro os planos daí 😉'
update public.config_mari_textos set texto = $t$Oi, {nome}, tudo bem? 💚

Aqui é a Mari, da Nio. Os planos de fibra vão de 600 Mega a 1 Giga, e o valor que você fechar agora fica travado até janeiro de 2030, sem reajuste todo ano.

Me manda seu CEP (ou o nome da rua e o bairro) que eu já te mostro os planos daí 😉$t$ where chave = 'abertura_fallback';

-- antes: 'Claro! 😊 Os planos vão de 600 Mega a 1 Giga, com preço fixo até 2030.\n\nO valor muda um pouquinho de cidade pra cidade. Me manda seu CEP (ou a rua e o bairro) que eu te mostro os planos e preços certinhos daí 👇'
update public.config_mari_textos set texto = $t$Claro! 😊 O valor muda um pouquinho de cidade pra cidade.

Me manda seu CEP (ou a rua e o bairro) que eu te mostro todos os planos com o preço certinho daí 👇$t$ where chave = 'abertura_resp_planos';

-- antes: 'trava2030,rua,cliente'
update public.config_mari_textos set texto = 'rua,planos,cliente' where chave = 'abertura_botoes';

-- antes: 'b2_081126'
update public.config_mari_textos set texto = 'b3_191126' where chave = 'abertura_versao';

do $$
begin
  if (select count(*) from public.config_mari_textos
       where (chave = 'abertura_versao' and texto = 'b3_191126')
          or (chave = 'abertura_botoes' and texto = 'rua,planos,cliente')
          or (chave in ('abertura_corpo', 'abertura_fallback') and texto like '%travado até janeiro de 2030%')
          or (chave = 'abertura_resp_planos' and texto like '%preço certinho daí%')) <> 5 then
    raise exception '0326: textos da abertura b3 não ficaram como esperado';
  end if;
end $$;

commit;
