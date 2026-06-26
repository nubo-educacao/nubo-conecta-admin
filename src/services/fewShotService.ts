import { supabase } from "@/integrations/supabase/client";

export interface FewShotExample {
  id: string;
  starter_id: string | null;
  category: string;
  user_message: string;
  expected_tools: string[];
  expected_response: string;
  is_active: boolean;
  sort_order: number;
  created_at: string;
  updated_at: string;
}

export interface CreateFewShotDTO {
  starter_id?: string | null;
  category: string;
  user_message: string;
  expected_tools: string[];
  expected_response: string;
  is_active: boolean;
  sort_order: number;
}

export const getFewShotExamples = async (): Promise<FewShotExample[]> => {
  const { data, error } = await supabase
    .from("few_shot_examples")
    .select("*")
    .order("sort_order", { ascending: true });

  if (error) {
    console.error("Error fetching few_shot_examples:", error);
    throw error;
  }

  return (data ?? []).map((row: any) => ({
    ...row,
    expected_tools: Array.isArray(row.expected_tools) ? row.expected_tools : [],
  })) as FewShotExample[];
};

export const createFewShotExample = async (dto: CreateFewShotDTO): Promise<FewShotExample> => {
  const { data, error } = await supabase
    .from("few_shot_examples")
    .insert([{ ...dto, expected_tools: dto.expected_tools }])
    .select()
    .limit(1);

  if (error) {
    console.error("Error creating few_shot_example:", error);
    throw error;
  }

  return data![0] as FewShotExample;
};

export const updateFewShotExample = async (
  id: string,
  dto: Partial<CreateFewShotDTO>
): Promise<void> => {
  const { error } = await supabase
    .from("few_shot_examples")
    .update({ ...dto, updated_at: new Date().toISOString() } as any)
    .eq("id", id);

  if (error) {
    console.error("Error updating few_shot_example:", error);
    throw error;
  }
};

export const deleteFewShotExample = async (id: string): Promise<void> => {
  const { error } = await supabase
    .from("few_shot_examples")
    .delete()
    .eq("id", id);

  if (error) {
    console.error("Error deleting few_shot_example:", error);
    throw error;
  }
};

export const reorderFewShotExamples = async (orderedIds: string[]): Promise<void> => {
  const updates = orderedIds.map((id, index) =>
    supabase
      .from("few_shot_examples")
      .update({ sort_order: index, updated_at: new Date().toISOString() } as any)
      .eq("id", id)
  );

  const results = await Promise.allSettled(updates);
  const failed = results.filter((r) => r.status === "rejected");
  if (failed.length > 0) {
    console.error("Some reorder updates failed:", failed);
    throw new Error("Falha ao reordenar alguns examples.");
  }
};
