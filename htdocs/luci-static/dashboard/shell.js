function createSectionState(expanded) {
  return {
    expanded,
    loaded: false,
    loading: false,
    error: null,
  };
}

export function buildSectionState() {
  const record = createSectionState(false);
  const feature = createSectionState(false);

  return {
    overview: createSectionState(true),
    users: createSectionState(false),
    network: createSectionState(false),
    system: createSectionState(false),
    record,
    feature,
    settings: createSectionState(false),
    records: record,
    features: feature,
  };
}
