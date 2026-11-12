-- NIOGEN | 0150_norm_geo_abreviacoes.sql | 12/11/2026 — Claude Code (mesmo prompt da 0149)
-- Resumo: o DFV abrevia bairro ("JD IPE", "N SRA GRACAS", "BARREIRA TRIUNFO", "VL NOVA VISTA") e o ViaCEP escreve por extenso
-- ("Jardim Ipê", "Nossa Senhora das Graças", "Barreira do Triunfo"). _norm_geo passa a expandir as abreviações e tirar
-- de/da/do/das/dos/e, para o "DFV tem fachada no bairro?" do retrato casar os dois. Recalcula as colunas geradas.

create or replace function public._norm_geo(t text) returns text language plpgsql immutable as $$
declare
  x text;
  r text[];
  trocas text[][] := array[
    array['\mN\s+SRA\M', 'NOSSA SENHORA'], array['\mNSA?\s+SRA\M', 'NOSSA SENHORA'], array['\mSRA\M', 'SENHORA'],
    array['\mJDM?\M', 'JARDIM'], array['\mVL\M', 'VILA'], array['\mSTA\M', 'SANTA'], array['\mSTO\M', 'SANTO'],
    array['\mPQE?\M', 'PARQUE'], array['\mCJ\M', 'CONJUNTO'], array['\mCONJ\M', 'CONJUNTO'], array['\mRES\M', 'RESIDENCIAL'],
    array['\mDR\M', 'DOUTOR'], array['\mPRES\M', 'PRESIDENTE'],
    array['\m(DE|DA|DO|DAS|DOS|E)\M', ' ']];
begin
  x := upper(translate(coalesce(t, ''), 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇáàâãäéèêëíìîïóòôõöúùûüç',
                                        'AAAAAEEEEIIIIOOOOOUUUUCaaaaaeeeeiiiiooooouuuuc'));
  x := regexp_replace(x, '\(.*?\)', ' ', 'g');
  x := regexp_replace(x, '[^A-Z0-9 ]', ' ', 'g');
  x := regexp_replace(x, '^\s*BAIRRO\s+', '');
  foreach r slice 1 in array trocas loop
    x := regexp_replace(x, r[1], r[2], 'g');
  end loop;
  return nullif(btrim(regexp_replace(x, '\s+', ' ', 'g')), '');
end $$;
comment on function public._norm_geo(text) is
  'Nome de cidade/bairro comparável: maiúsculas, sem acento, sem parênteses nem prefixo BAIRRO, abreviações do DFV expandidas '
  '(JD, VL, STA, STO, N SRA, PQ, CJ, RES) e sem de/da/do/das/dos/e. 0149/0150.';

-- recalcula as colunas geradas com a regra nova
update public.dfv_cobertura_bairro set bairro = bairro;
update public.dfv_cobertura_cidade set cidade = cidade;
