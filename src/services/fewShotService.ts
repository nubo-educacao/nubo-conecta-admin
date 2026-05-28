import { supabase } from "@/integrations/supabase/client";

export interface LearningExample {
  id: string;
  intent_category: string;
  input_query: string;
  ideal_output: string;
  is_active: boolean;
  source: string;
  reasoning: string | null;
  created_at: string;
}

export interface CreateLearningExampleDTO {
  intent_category: string;
  input_query: string;
  ideal_output: string;
  is_active: boolean;
  source?: string;
  reasoning?: string;
}

export const getLearningExamples = async (): Promise<LearningExample[]> => {
  const { data, error } = await supabase
    .from("learning_examples")
    .select("*")
    .order("created_at", { ascending: false });

  if (error) {
    console.error("Error fetching learning_examples:", error);
    throw error;
  }

  return (data ?? []) as LearningExample[];
};

export const createLearningExample = async (dto: CreateLearningExampleDTO): Promise<LearningExample> => {
  const payload = {
    ...dto,
    source: dto.source || "admin",
  };

  const { data, error } = await supabase
    .from("learning_examples")
    .insert([payload])
    .select()
    .limit(1);

  if (error) {
    console.error("Error creating learning_example:", error);
    throw error;
  }

  return data![0] as LearningExample;
};

export const updateLearningExample = async (
  id: string,
  dto: Partial<CreateLearningExampleDTO>
): Promise<void> => {
  const { error } = await supabase
    .from("learning_examples")
    .update({ ...dto } as any)
    .eq("id", id);

  if (error) {
    console.error("Error updating learning_example:", error);
    throw error;
  }
};

export const deleteLearningExample = async (id: string): Promise<void> => {
  const { error } = await supabase
    .from("learning_examples")
    .delete()
    .eq("id", id);

  if (error) {
    console.error("Error deleting learning_example:", error);
    throw error;
  }
};
