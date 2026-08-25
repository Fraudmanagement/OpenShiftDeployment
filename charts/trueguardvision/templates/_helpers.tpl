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

{{/* placement.spreadAll açık mı? (values'ta placement bloğu hiç yoksa kapalı) */}}
{{- define "trueguardvision.spreadAll" -}}
{{- if and .Values.placement .Values.placement.spreadAll -}}true{{- end -}}
{{- end -}}

{{/* spreadAll affinity'si: tgv-spread etiketli HİÇBİR pod'la aynı node'a düşme.
     Tüm pod'lar bu etiketi taşıdığından sonuç: her pod ayrı node.
     DİKKAT: spreadAll açıkken çiftli placement ayarları (engine.dragonflyPlacement,
     simulator.engine.fraudEnginePlacement) EZİLİR — colocate dahil, hiç uygulanmaz. */}}
{{- define "trueguardvision.spreadAffinity" -}}
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            tgv-spread: "true"
        topologyKey: kubernetes.io/hostname
{{- end -}}
