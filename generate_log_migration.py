import re

with open('supabase/migrations/20260605190000_truncate_raw_tables_on_success.sql', 'r', encoding='utf-8') as f:
    content = f.read()

# Replace Vagas log
vagas_old_log = r"""    v_detail_msg :=
      'Vagas SiSU importadas com sucesso.' \|\|
      chr\(10\) \|\| '• Linhas no arquivo raw:          ' \|\| v_raw_count \|\|
      chr\(10\) \|\| '• Vagas vinculadas \(mapeadas\):    ' \|\| v_processed \|\|
      chr\(10\) \|\| '• Linhas ignoradas \(s/ opp\.\):     ' \|\| v_skipped \|\|
      chr\(10\) \|\| '• Registros em sisu_vacancies:    ' \|\| v_vacancies_in_db \|\|
      chr\(10\) \|\| '• Oportunidades c/ vaga:          ' \|\| v_opps_with_vaga \|\| ' / ' \|\| v_opps_total \|\|
      chr\(10\) \|\| '• Oportunidades s/ vaga:          ' \|\| v_opps_without_vaga \|\|
      chr\(10\) \|\| '• Vagas c/ histórico propagado:   ' \|\| COALESCE\(v_historical_prop, 0\);"""

vagas_new_log = """    v_detail_msg :=
      'Termo de Adesão (Vagas) importado com sucesso.' ||
      chr(10) || '• Linhas no arquivo raw:          ' || v_raw_count ||
      chr(10) || '• Oportunidades criadas/atualizadas: ' || v_processed ||
      chr(10) || '• Total de oportunidades na base: ' || v_opps_total ||
      chr(10) || '• Vagas c/ histórico propagado:   ' || COALESCE(v_historical_prop, 0);"""

content = re.sub(vagas_old_log, vagas_new_log, content)

# Replace Base log
base_old_log = r"""    v_detail_msg :=
      'Base SiSU importada com sucesso.' \|\|
      chr\(10\) \|\| '• Linhas no arquivo raw:          ' \|\| v_raw_count \|\|
      chr\(10\) \|\| '• IES distintas:                  ' \|\| v_inst_count \|\|
      chr\(10\) \|\| '• Campus distintos:               ' \|\| v_campus_count \|\|
      chr\(10\) \|\| '• Cursos distintos:               ' \|\| v_course_count \|\|
      chr\(10\) \|\| '• Oportunidades criadas/atualizadas: ' \|\| v_opp_count \|\|
      chr\(10\) \|\| '• Opps\. com nota de corte:        ' \|\| v_opp_with_cutoff \|\|
      chr\(10\) \|\| '• Opps\. sem nota de corte:        ' \|\| v_opp_no_cutoff;"""

base_new_log = """    v_detail_msg :=
      'Base Consolidada importada com sucesso.' ||
      chr(10) || '• Linhas no arquivo raw:          ' || v_raw_count ||
      chr(10) || '• IES distintas:                  ' || v_inst_count ||
      chr(10) || '• Campus distintos:               ' || v_campus_count ||
      chr(10) || '• Cursos distintos:               ' || v_course_count ||
      chr(10) || '• Oportunidades processadas:      ' || v_processed ||
      chr(10) || '• Opps. validadas com nota:       ' || v_opp_with_cutoff ||
      chr(10) || '• Opps. criadas p/ falta de match:' || (v_opp_count - v_processed);"""

content = re.sub(base_old_log, base_new_log, content)

with open('supabase/migrations/20260605194500_adjust_sisu_etl_logs.sql', 'w', encoding='utf-8') as f:
    f.write("-- Adjust SiSU ETL Logs to reflect Vacancies-first flow\n-- 20260605194500_adjust_sisu_etl_logs.sql\n\n" + content)
