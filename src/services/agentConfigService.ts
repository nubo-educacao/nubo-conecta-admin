import { supabase } from "@/integrations/supabase/client";

export interface CloudinhaStarter {
  id: string;
  page_route: string;
  route_priority: number | null;
  intro_message: string | null;
  starters: string[];
  is_active: boolean | null;
}

export interface AgentPrompt {
  id: string;
  agent_key: string;
  system_instruction: string;
  temperature: number | null;
  is_active: boolean | null;
  updated_at: string | null;
  model: string | null;        // NOVO
  max_steps: number | null;    // NOVO
}

export const getCloudinhaStarters = async (): Promise<CloudinhaStarter[]> => {
  const { data, error } = await supabase
    .from("cloudinha_starters")
    .select("*")
    .order("route_priority", { ascending: false });

  if (error) {
    console.error("Error fetching starters:", error);
    throw error;
  }

  return data as CloudinhaStarter[];
};

export const upsertCloudinhaStarter = async (starter: Partial<CloudinhaStarter>): Promise<void> => {
  if (!starter.id) {
    const { error } = await supabase.from("cloudinha_starters").insert([starter as any]);
    if (error) {
      console.error("Error inserting starter:", error);
      throw error;
    }
    return;
  }
  
  const { error } = await supabase
    .from("cloudinha_starters")
    .update(starter as any)
    .eq("id", starter.id);

  if (error) {
    console.error("Error updating starter:", error);
    throw error;
  }
};

export const deleteCloudinhaStarter = async (id: string): Promise<void> => {
  const { error } = await supabase
    .from("cloudinha_starters")
    .delete()
    .eq("id", id);

  if (error) {
    console.error("Error deleting starter:", error);
    throw error;
  }
};

export const getAgentPrompts = async (): Promise<AgentPrompt[]> => {
  const { data, error } = await supabase
    .from("agent_prompts")
    .select("*")
    .eq("is_active", true)      // NOVO: exclui legados
    .order("agent_key", { ascending: true });

  if (error) {
    console.error("Error fetching agent prompts:", error);
    throw error;
  }

  return data as AgentPrompt[];
};

export const updateAgentPrompt = async (id: string, promptData: Partial<AgentPrompt>): Promise<void> => {
  const { error } = await supabase
    .from("agent_prompts")
    .update(promptData as any)
    .eq("id", id);

  if (error) {
    console.error("Error updating agent prompt:", error);
    throw error;
  }
};
