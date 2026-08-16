{{/* Route host'ları: values'ta doluysa onu, boşsa <ad>.<clusterDomain> kullan */}}
{{- define "trueguardvision.fmHost" -}}
{{ .Values.routes.fmHost | default (printf "fm.%s" .Values.clusterDomain) }}
{{- end -}}

{{- define "trueguardvision.simHost" -}}
{{ .Values.routes.simHost | default (printf "sim.%s" .Values.clusterDomain) }}
{{- end -}}

{{- define "trueguardvision.simEngineHost" -}}
{{ .Values.routes.simEngineHost | default (printf "sim-engine.%s" .Values.clusterDomain) }}
{{- end -}}
