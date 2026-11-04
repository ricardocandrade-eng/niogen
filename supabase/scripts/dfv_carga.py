# NIOGEN | supabase/scripts/dfv_carga.py | 03/11/2026
# Carga da base DFV da Nio (CSV por município) pelo CLI, enquanto a tela de importação só faz a prévia.
# Gera arquivos SQL FORA do repo (o dado é da Nio): 00 cria a importação, 01..N enchem nio_hp_stage, 99 chama aplicar_dfv.
#
#   python -I supabase/scripts/dfv_carga.py <arquivo.csv> <pasta_saida_fora_do_repo> <uuid_do_admin> [linhas_por_lote]
#   for f in <pasta>/*.sql; do npx.cmd supabase db query --remote --yes -f "$f"; done
#
# CSV esperado: ';' · UTF-8 com BOM · CRLF · sem aspas (o arquivo de 03/11 não tem nenhuma; se vier, o script para).
import os
import sys
import uuid

COLUNAS = [
    'UF', 'MUNICIPIO', 'CELULA', 'LOCALIDADE', 'CODIGO_LOGRADOURO', 'LOGRADOURO', 'NO_FACHADA', 'COMPLEMENTO1',
    'COMPLEMENTO2', 'COMPLEMENTO3', 'CEP', 'BAIRRO', 'LATITUDE', 'LONGITUDE', 'VIABILIDADE_ATUAL', 'HP_LIVRE',
    'SIGLA_ESTACAO_ABASTECEDORA', 'CODIGO_CDO', 'TIPO_EDIFICACAO', 'TIPO_ENDERECO', 'GIRO_MEDIO_6M_CEL',
    'VLL_MEDIA_6M_CEL', 'GROSS_MEDIA_6M_CEL', 'FLAG_GROSS_6M_CEL', 'PERC_HPS_AREA_RISCO', 'HC_EMP', 'CLASSIFICACAO',
    'CHAVE', 'COD_SURVEY', 'ID_VIABILIDADE', 'HP_VAR', 'HP_EMP', 'HP_TOT', 'HC_TOT', 'HC_VAR', 'F_HP_NOVO',
    'DT_CONSTRUCAO_2025', 'PROJETO_HP_NOVO', 'SCORE_MEDIO_CEL', 'PCT_APROV_IND_LOC_OUT_CEL', 'QT_PROPOSTAS_BAIRRO',
    'PCT_APROVADOS_BAIRRO', 'PCT_APROVADOS_CC_BAIRRO', 'PCT_POSSE_CARTAO_BAIRRO', 'dt_dfv_particao',
    'ds_classe_social_dominante', 'ds_faixa_aprovacao_credito_total', 'ds_faixa_aprovacao_credito_local',
    'ds_faixa_posse_cartao',
]


def lit(v):
    return "''" if v == '' else "'" + v.replace("'", "''") + "'"


def main():
    csv, saida, admin = sys.argv[1], sys.argv[2], sys.argv[3]
    por_lote = int(sys.argv[4]) if len(sys.argv) > 4 else 4000
    uuid.UUID(admin)
    with open(csv, encoding='utf-8-sig', newline='') as f:
        texto = f.read()
    if '"' in texto:
        sys.exit('CSV com aspas: este carregador não trata campos entre aspas.')
    linhas = [l for l in texto.replace('\r\n', '\n').split('\n') if l != '']
    cab = linhas[0].split(';')
    if sorted(cab) != sorted(COLUNAS):
        sys.exit('Colunas diferentes do DFV de 03/11: ' + ', '.join(sorted(set(cab) ^ set(COLUNAS))))
    corpo = [l.split(';') for l in linhas[1:]]
    ruins = [i + 2 for i, r in enumerate(corpo) if len(r) != len(cab)]
    if ruins:
        sys.exit(f'{len(ruins)} linhas com nº de colunas errado (ex.: {ruins[:5]}).')

    os.makedirs(saida, exist_ok=True)
    imp = str(uuid.uuid4())
    nome = os.path.basename(csv)
    cols = ', '.join(c.lower() for c in cab)
    with open(os.path.join(saida, '00_importacao.sql'), 'w', encoding='utf-8') as f:
        f.write(f"insert into public.importacoes (id, tipo, arquivo_nome, linhas, criado_por, resumo)\n"
                f"values ('{imp}', 'dfv_hp', {lit(nome)}, {len(corpo)}, '{admin}', "
                f"jsonb_build_object('origem', 'cli', 'arquivo', {lit(nome)}));\n")
    n = 0
    for i in range(0, len(corpo), por_lote):
        n += 1
        valores = ',\n'.join(
            f"('{imp}',{i + j + 1}," + ','.join(lit(v) for v in r) + ')' for j, r in enumerate(corpo[i:i + por_lote]))
        with open(os.path.join(saida, f'{n:02d}_stage.sql'), 'w', encoding='utf-8') as f:
            f.write(f'insert into public.nio_hp_stage (importacao_id, linha, {cols}) values\n{valores};\n')
    # aplicar_dfv exige perfil admin/backoffice: a sessão do CLI assume o admin só nesta transação.
    with open(os.path.join(saida, '99_aplicar.sql'), 'w', encoding='utf-8') as f:
        f.write(f"with c as materialized (select set_config('request.jwt.claims', "
                f"'{{\"sub\":\"{admin}\",\"role\":\"authenticated\"}}', true))\n"
                f"select public.aplicar_dfv('{imp}') as resumo from c;\n")
    print(f'importacao_id={imp} linhas={len(corpo)} lotes={n} saida={saida}')


if __name__ == '__main__':
    main()
