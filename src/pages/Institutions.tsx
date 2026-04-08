// Institutions Admin Page — Sprint 02 Wave 5
// MEC CSV import pipeline UI:
//   1. Select importType (institutions | campus | courses)
//   2. Drag-and-drop or file input for CSV/JSON file
//   3. Progress bar during upload + import
//   4. Error log display from import response
//
// Uses papaparse (already in package.json) to parse CSV → JSON before upload.
// PLAYBOOK § 2: Admin uses client-side state + TanStack Query pattern.

import React, { useCallback, useRef, useState } from 'react';
import Papa from 'papaparse';
import {
  generateUploadUrl,
  triggerImport,
  type ImportType,
} from '@/services/importPipelineService';

type ProgressStep = 'idle' | 'parsing' | 'uploading' | 'importing' | 'done' | 'error';

export default function InstitutionsPage() {
  const [importType, setImportType] = useState<ImportType>('institutions');
  const [step, setStep]             = useState<ProgressStep>('idle');
  const [progress, setProgress]     = useState(0);
  const [processed, setProcessed]   = useState<number | null>(null);
  const [errors, setErrors]         = useState<string[]>([]);
  const [dragOver, setDragOver]     = useState(false);
  const fileInputRef                = useRef<HTMLInputElement>(null);

  const handleFile = useCallback(
    async (file: File) => {
      if (!file) return;
      setStep('parsing');
      setProgress(10);
      setErrors([]);
      setProcessed(null);

      try {
        // Parse CSV → JSON using papaparse
        const jsonRecords = await new Promise<Record<string, string>[]>((resolve, reject) => {
          Papa.parse<Record<string, string>>(file, {
            header:        true,
            skipEmptyLines: true,
            complete: (results) => resolve(results.data),
            error:    (err)     => reject(new Error(err.message)),
          });
        });

        setStep('uploading');
        setProgress(30);

        // Get signed URL from Edge Function
        const { signedUrl, path } = await generateUploadUrl(
          `${importType}_${file.name.replace(/\s+/g, '_')}.json`,
        );

        // Upload JSON content directly to Storage via signed URL
        const jsonBlob = new Blob([JSON.stringify(jsonRecords)], { type: 'application/json' });
        const uploadRes = await fetch(signedUrl, {
          method: 'PUT',
          body:   jsonBlob,
          headers: { 'Content-Type': 'application/json' },
        });

        if (!uploadRes.ok) {
          throw new Error(`Upload failed: HTTP ${uploadRes.status}`);
        }

        setProgress(60);
        setStep('importing');

        // Trigger import via Edge Function
        const result = await triggerImport(path, importType);
        setProcessed(result.processed);
        setErrors(result.errors);
        setProgress(100);
        setStep('done');
      } catch (err) {
        setErrors([(err as Error).message]);
        setStep('error');
        setProgress(0);
      }
    },
    [importType],
  );

  const handleInputChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) handleFile(file);
  };

  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    setDragOver(false);
    const file = e.dataTransfer.files?.[0];
    if (file) handleFile(file);
  };

  const stepLabels: Record<ProgressStep, string> = {
    idle:      'Aguardando arquivo...',
    parsing:   'Processando CSV...',
    uploading: 'Enviando para Storage...',
    importing: 'Importando registros...',
    done:      'Importação concluída!',
    error:     'Erro na importação',
  };

  return (
    <div className="p-6 max-w-3xl mx-auto">
      <h1 className="text-2xl font-bold text-gray-800 mb-6">Importação MEC — Dados CSV</h1>

      {/* Import type selector */}
      <div className="mb-6">
        <label className="block text-sm font-semibold text-gray-600 mb-2">
          Tipo de Importação
        </label>
        <select
          value={importType}
          onChange={(e) => setImportType(e.target.value as ImportType)}
          className="w-full border border-gray-200 rounded-lg px-4 py-2.5 text-sm text-gray-800 focus:outline-none focus:ring-2 focus:ring-blue-500"
          disabled={step !== 'idle' && step !== 'done' && step !== 'error'}
        >
          <option value="institutions">Instituições (institutions)</option>
          <option value="campus">Campi (campus)</option>
          <option value="courses">Cursos + Oportunidades (courses)</option>
        </select>
        <p className="text-xs text-gray-500 mt-1">
          Processe na ordem: <strong>Instituições → Campi → Cursos</strong>
        </p>
      </div>

      {/* Dropzone */}
      <div
        onDragOver={(e) => { e.preventDefault(); setDragOver(true); }}
        onDragLeave={() => setDragOver(false)}
        onDrop={handleDrop}
        onClick={() => fileInputRef.current?.click()}
        className={`border-2 border-dashed rounded-xl p-10 text-center cursor-pointer transition-colors ${
          dragOver ? 'border-blue-500 bg-blue-50' : 'border-gray-300 hover:border-gray-400'
        }`}
      >
        <input
          ref={fileInputRef}
          type="file"
          accept=".csv"
          onChange={handleInputChange}
          className="hidden"
        />
        <p className="text-gray-500 text-sm">
          Arraste um arquivo CSV aqui ou{' '}
          <span className="text-blue-600 font-semibold">clique para selecionar</span>
        </p>
        <p className="text-xs text-gray-400 mt-1">Formato esperado: CSV com cabeçalho</p>
      </div>

      {/* Progress bar */}
      {step !== 'idle' && (
        <div className="mt-6">
          <div className="flex justify-between items-center mb-2">
            <span className="text-sm font-medium text-gray-700">{stepLabels[step]}</span>
            <span className="text-sm text-gray-500">{progress}%</span>
          </div>
          <div className="w-full bg-gray-200 rounded-full h-2">
            <div
              className={`h-2 rounded-full transition-all duration-500 ${
                step === 'error' ? 'bg-red-500' : step === 'done' ? 'bg-green-500' : 'bg-blue-500'
              }`}
              style={{ width: `${progress}%` }}
            />
          </div>
        </div>
      )}

      {/* Results */}
      {step === 'done' && processed !== null && (
        <div className="mt-4 p-4 bg-green-50 border border-green-200 rounded-lg">
          <p className="text-green-800 font-semibold text-sm">
            {processed} registro{processed !== 1 ? 's' : ''} processado{processed !== 1 ? 's' : ''} com sucesso.
          </p>
        </div>
      )}

      {/* Error log */}
      {errors.length > 0 && (
        <div className="mt-4 p-4 bg-red-50 border border-red-200 rounded-lg max-h-48 overflow-y-auto">
          <p className="text-red-800 font-semibold text-sm mb-2">
            {errors.length} erro{errors.length !== 1 ? 's' : ''} encontrado{errors.length !== 1 ? 's' : ''}:
          </p>
          <ul className="space-y-1">
            {errors.map((err, i) => (
              <li key={i} className="text-red-700 text-xs font-mono">
                {err}
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* Reset button */}
      {(step === 'done' || step === 'error') && (
        <button
          onClick={() => { setStep('idle'); setProgress(0); setErrors([]); setProcessed(null); }}
          className="mt-4 px-4 py-2 text-sm font-semibold text-gray-700 border border-gray-300 rounded-lg hover:bg-gray-50 transition-colors"
        >
          Nova importação
        </button>
      )}
    </div>
  );
}
