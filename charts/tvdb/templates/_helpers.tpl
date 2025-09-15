{{- define "tvdb.storageSecretName" -}}
{{- if .Values.storage.existingSecret -}}
{{ .Values.storage.existingSecret }}
{{- else -}}
{{ printf "%s-storage" .Release.Name }}
{{- end -}}
{{- end -}}

{{- define "tvdb.appSecretName" -}}
{{- if .Values.app.existingSecret -}}
{{ .Values.app.existingSecret }}
{{- else -}}
{{ printf "%s-app" .Release.Name }}
{{- end -}}
{{- end -}}
