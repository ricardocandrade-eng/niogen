-- NIOGEN | supabase/migrations/0104_confirmacao_sem_emoji_triste.sql | 10/11/2026 — Claude Code
-- Por quê: na conferência da 0103 (7 dias de falas reais), um "😭" sozinho virou confirmação. Ricardo (10/11): "Sim, tirar".
-- O quê: config_regras.confirmacao_cliente ganha "emojis_fora" (choro, tristeza, raiva, 👎) — fala com qualquer um deles NUNCA é
-- confirmação (pede resposta). texto_confirmacao() lê a lista; o resto da regra é igual. Regra 15: lista em config.

begin;

update public.config_regras
   set valor = valor || jsonb_build_object('emojis_fora',
         jsonb_build_array('😭', '😢', '😥', '😪', '😿', '😞', '😔', '😟', '🙁', '☹', '😩', '😫', '😣', '😖', '😠', '😡', '🤬', '😤', '💔', '👎')),
       atualizado_em = now()
 where chave = 'confirmacao_cliente';

create or replace function public.texto_confirmacao(p_texto text)
returns boolean language plpgsql stable set search_path = public as $$
declare
  cfg  jsonb;
  t    text;
  s    text;
  ant  text;
  f    text;
begin
  if p_texto is null then return false; end if;
  t := btrim(p_texto);
  select valor into cfg from public.config_regras where chave = 'confirmacao_cliente';
  if cfg is null or t = '' then return false; end if;
  if char_length(t) > coalesce((cfg ->> 'max_chars')::int, 25) then return false; end if;
  if t ~ '[?¿0-9@]' or t ~ '^\[' then return false; end if;   -- pergunta, número/CEP/CPF, e-mail, [áudio]/[imagem]
  -- 0104: emoji de choro/tristeza/raiva/👎 = o cliente não está só confirmando
  if exists (select 1 from jsonb_array_elements_text(coalesce(cfg -> 'emojis_fora', '[]'::jsonb)) e where strpos(t, e) > 0) then
    return false;
  end if;
  s := lower(translate(t, 'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ', 'aaaaaeeeeiiiiooooouuuucaaaaaeeeeiiiiooooouuuuc'));
  if s !~ '[a-z]' then
    -- só emoji (pontuação sozinha não conta)
    return regexp_replace(s, '[[:space:][:punct:]]', '', 'g') <> '';
  end if;
  s := regexp_replace(s, '[^a-z]+', ' ', 'g');                 -- emoji e pontuação viram espaço
  s := regexp_replace(s, '([a-z])\1{2,}', '\1', 'g');          -- "obrigadaaa" → "obrigada"
  s := ' ' || btrim(regexp_replace(s, '\s+', ' ', 'g')) || ' ';
  loop
    ant := s;
    for f in select x from jsonb_array_elements_text(coalesce(cfg -> 'frases', '[]'::jsonb)) x order by char_length(x) desc loop
      s := replace(s, ' ' || f || ' ', ' ');
    end loop;
    exit when s = ant;
  end loop;
  return btrim(s) = '';
end;
$$;

commit;
