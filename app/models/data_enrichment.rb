class DataEnrichment < ApplicationRecord
  belongs_to :enrichable, polymorphic: true

  enum :source, {
    rule: "rule",
    synth: "synth",
    ai: "ai",
    bayes: "bayes"
  }
end
