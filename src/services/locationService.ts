import { supabase } from "@/integrations/supabase/client";

export interface State {
    uf: string;
    name: string;
}

export interface City {
    id: number;
    name: string;
    state: string;
}

export const getStates = async (): Promise<State[]> => {
    const { data, error } = await supabase
        .from('states')
        .select('*')
        .order('name');

    if (error) throw error;
    return data as State[];
};

export const getCities = async (state: string, query: string): Promise<City[]> => {
    let queryBuilder = supabase
        .from('cities')
        .select('*')
        .ilike('name', `%${query}%`)
        .limit(20);

    if (state) {
        queryBuilder = queryBuilder.eq('state', state);
    }

    const { data, error } = await queryBuilder;

    if (error) throw error;
    return data as City[];
};
