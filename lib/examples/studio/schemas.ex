defmodule JidoRunic.Examples.Studio.Schemas do
  @moduledoc """
  Data schemas for the AI Research Studio workflow facts.
  """

  defmodule QueryPlan do
    @moduledoc false
    defstruct [:topic, :audience, queries: [], outline_seed: []]
  end

  defmodule SourceDoc do
    @moduledoc false
    defstruct [:url, :title, :content, :snippet, :retrieved_at]
  end

  defmodule Claim do
    @moduledoc false
    defstruct [:text, :quote, :url, :confidence, tags: []]
  end

  defmodule Outline do
    @moduledoc false
    defstruct [:topic, sections: []]
  end

  defmodule OutlineSection do
    @moduledoc false
    defstruct [:id, :title, :intent, required_tags: []]
  end

  defmodule SectionDraft do
    @moduledoc false
    defstruct [:section_id, :title, :markdown, citations: [], used_claim_hashes: []]
  end

  defmodule Article do
    @moduledoc false
    defstruct [:markdown, :quality_score, citations: [], sections: []]
  end
end
