function createSectionState(expanded) {
  return {
    expanded,
    loaded: false,
    loading: false,
    error: null,
  };
}

export function buildSectionState() {
  const features = createSectionState(false);

  return {
    overview: createSectionState(true),
    users: createSectionState(false),
    network: createSectionState(false),
    system: createSectionState(false),
    records: createSectionState(false),
    features,
    feature: features,
    settings: createSectionState(false),
  };
}
