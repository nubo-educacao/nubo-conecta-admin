import { useSearchParams } from "react-router-dom";
import { StudentFilters } from "@/services/studentsService";
import { useCallback, useMemo, useEffect, useState } from "react";

const QUERY_DEBOUNCE_MS = 300; // Debounce query updates to avoid too many writes

export function useStudentFilters(storageKey: string = "student-filters") {
    const [searchParams, setSearchParams] = useSearchParams();
    const [initialized, setInitialized] = useState(false);

    // 1. Load initial state from localStorage if URL is empty on mount
    useEffect(() => {
        // Only checking if searchParams is empty (no keys)
        if (Array.from(searchParams.keys()).length === 0) {
            const stored = localStorage.getItem(storageKey);
            if (stored) {
                setSearchParams(new URLSearchParams(stored));
            }
        }
        setInitialized(true);
    }, []); // Run once on mount

    // 2. Sync URL changes to localStorage
    useEffect(() => {
        if (!initialized) return;

        const paramsString = searchParams.toString();

        // Handle clearing: if initialized and params empty, we want to clear storage
        // But we need to distinguish between "just loaded empty" and "user cleared"
        // Actually, simple sync is fine because we blocked the initial empty overwrite with 'initialized'
        localStorage.setItem(storageKey, paramsString);
    }, [searchParams, storageKey, initialized]);

    const filters = useMemo((): StudentFilters => {
        const params: StudentFilters = {};

        const fullName = searchParams.get("fullName");
        if (fullName) params.fullName = fullName;

        const city = searchParams.get("city");
        if (city) params.city = city;

        const education = searchParams.get("education");
        if (education) params.education = education;

        const isNuboStudent = searchParams.get("isNuboStudent");
        if (isNuboStudent === "true") params.isNuboStudent = true;
        if (isNuboStudent === "false") params.isNuboStudent = false;

        const incomeMin = searchParams.get("incomeMin");
        if (incomeMin) params.incomeMin = Number(incomeMin);

        const incomeMax = searchParams.get("incomeMax");
        if (incomeMax) params.incomeMax = Number(incomeMax);

        const quotaTypes = searchParams.getAll("quotaTypes");
        if (quotaTypes.length > 0) params.quotaTypes = quotaTypes;

        const state = searchParams.get("state");
        if (state) params.state = state;

        const ageMin = searchParams.get("ageMin");
        if (ageMin) params.ageMin = Number(ageMin);

        const ageMax = searchParams.get("ageMax");
        if (ageMax) params.ageMax = Number(ageMax);

        return params;
    }, [searchParams]);

    const setFilters = useCallback((newFilters: StudentFilters) => {
        const params = new URLSearchParams();

        if (newFilters.fullName) params.set("fullName", newFilters.fullName);
        if (newFilters.city) params.set("city", newFilters.city);
        if (newFilters.education) params.set("education", newFilters.education);

        if (newFilters.isNuboStudent === true) params.set("isNuboStudent", "true");
        if (newFilters.isNuboStudent === false) params.set("isNuboStudent", "false");

        if (newFilters.incomeMin) params.set("incomeMin", newFilters.incomeMin.toString());
        if (newFilters.incomeMax) params.set("incomeMax", newFilters.incomeMax.toString());

        if (newFilters.quotaTypes) {
            newFilters.quotaTypes.forEach(q => params.append("quotaTypes", q));
        }

        if (newFilters.state) params.set("state", newFilters.state);
        if (newFilters.ageMin) params.set("ageMin", newFilters.ageMin.toString());
        if (newFilters.ageMax) params.set("ageMax", newFilters.ageMax.toString());

        setSearchParams(params);
    }, [setSearchParams]);

    const clearFilters = useCallback(() => {
        setSearchParams(new URLSearchParams());
        localStorage.removeItem(storageKey);
    }, [setSearchParams, storageKey]);

    return { filters, setFilters, clearFilters };
}
