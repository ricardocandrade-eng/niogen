-- NIOGEN | supabase/migrations/0387_abertura_sou_cliente_espaco.sql | 24/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 24/11, depois de testar em conversa real a pergunta do "🏠 Sou cliente Nio" (0386): "adicione um espaço entre as
-- opções dentro do balão". Só o texto: uma linha em branco entre as três opções (📍 · 🛒 · 🔧). Nada mais muda.
-- Regra 20: não se aplica (texto de uma mensagem, sem estado, evento ou número novo).
begin;

update public.config_mari_textos set texto = $t$Que bom ter você com a gente! 💚

Me conta o que você precisa:

📍 Nio em outro endereço (da família, do trabalho, do comércio): isso é comigo, faço agora.

🛒 Ainda não tem Nio aí? Toca em Quero contratar.

🔧 Fatura, suporte ou mudança de plano: quem resolve é a própria Nio, eu te passo o caminho.$t$
 where chave = 'abertura_resp_cliente_pergunta';

do $$ begin
  if (select texto from public.config_mari_textos where chave = 'abertura_resp_cliente_pergunta') not like '%agora.' || chr(10) || chr(10) || '%' then
    raise exception '0387: texto não atualizado';
  end if;
end $$;

commit;
