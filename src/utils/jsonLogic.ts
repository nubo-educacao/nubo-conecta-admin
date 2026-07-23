/**
 * Lightweight JSON Logic evaluator for conditional form fields.
 * Ported from nubo-conecta-app — Sprint QA-7
 */

function extractNumericValue(val: unknown): number | null {
    if (val == null) return null;
    if (typeof val === 'number') return isNaN(val) ? null : val;

    if (typeof val === 'object' && val !== null) {
        if ('per_capita_income' in val) return extractNumericValue((val as Record<string, unknown>).per_capita_income);
        if ('value' in val) return extractNumericValue((val as Record<string, unknown>).value);
    }

    if (typeof val === 'string') {
        const trimmed = val.trim();
        if (trimmed === '') return null;
        if (!isNaN(Number(trimmed))) return Number(trimmed);
        if (!/\d/.test(trimmed)) return null;

        let clean = trimmed.replace(/[^\d.,-]/g, '');
        if (clean.includes(',') && clean.indexOf(',') > clean.lastIndexOf('.')) {
            clean = clean.replace(/\./g, '').replace(',', '.');
        } else if (clean.includes(',') && !clean.includes('.')) {
            clean = clean.replace(',', '.');
        } else if (clean.includes('.') && !clean.includes(',')) {
            const parts = clean.split('.');
            if (parts.length > 1 && parts[parts.length - 1].length === 3 && parts[0].length >= 1) {
                clean = clean.replace(/\./g, '');
            }
        } else {
            clean = clean.replace(/,/g, '');
        }

        const num = Number(clean);
        return isNaN(num) ? null : num;
    }

    return null;
}

export function evaluateJsonLogic(rule: unknown, data: Record<string, unknown>): unknown {
    if (Array.isArray(rule)) return rule.map(item => evaluateJsonLogic(item, data));
    if (typeof rule !== 'object' || rule === null) return rule;

    const ruleObj = rule as Record<string, unknown>;
    const keys = Object.keys(ruleObj);
    if (keys.length === 0) return false;

    const op = keys[0];
    let args = ruleObj[op];
    if (!Array.isArray(args)) args = [args];

    if (op === 'var') {
        const varName = (args as unknown[])[0] as string;
        return data[varName];
    }

    const evalArgs = (args as unknown[]).map((a) => evaluateJsonLogic(a, data));

    const compare = (a: unknown, b: unknown, opStr: string): boolean => {
        if (a == null || b == null) return false;
        const numA = extractNumericValue(a);
        const numB = extractNumericValue(b);
        const valA = numA !== null ? numA : a;
        const valB = numB !== null ? numB : b;
        switch (opStr) {
            case '>': return (valA as number) > (valB as number);
            case '>=': return (valA as number) >= (valB as number);
            case '<': return (valA as number) < (valB as number);
            case '<=': return (valA as number) <= (valB as number);
            default: return false;
        }
    };

    const normalizeValue = (val: unknown): unknown => {
        if (val === true || (typeof val === 'string' && val.toLowerCase() === 'sim')) return 'sim';
        if (val === false || (typeof val === 'string' && (val.toLowerCase() === 'não' || val.toLowerCase() === 'nao'))) return 'não';
        if (typeof val === 'string') {
            const trimmed = val.trim();
            if (trimmed !== '' && !isNaN(Number(trimmed))) return Number(trimmed);
            return trimmed.toLowerCase();
        }
        return val;
    };

    switch (op) {
        case '==':
        case '===':
            return normalizeValue(evalArgs[0]) === normalizeValue(evalArgs[1]);
        case '!=':
        case '!==':
            return normalizeValue(evalArgs[0]) !== normalizeValue(evalArgs[1]);
        case '>':
        case '>=':
        case '<':
        case '<=':
            return compare(evalArgs[0], evalArgs[1], op);
        case 'in':
            if (evalArgs[1] == null || evalArgs[0] == null) return false;
            if (Array.isArray(evalArgs[1])) {
                const val = evalArgs[0];
                if (typeof val === 'string') {
                    return (evalArgs[1] as unknown[]).some(x => String(x).trim().toLowerCase() === val.trim().toLowerCase());
                }
                return (evalArgs[1] as unknown[]).includes(val);
            }
            if (typeof evalArgs[1] === 'string') return evalArgs[1].includes(String(evalArgs[0]));
            return false;
        case 'and':
            return evalArgs.every(Boolean);
        case 'or':
            return evalArgs.some(Boolean);
        case '!':
            return !evalArgs[0];
        default:
            return false;
    }
}
