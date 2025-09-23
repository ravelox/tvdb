(() => {
  const state = {
    token: '',
    shows: [],
    seasons: [],
    episodes: [],
    characters: [],
    selectedShowId: null,
    selectedSeasonNumber: null,
    selectedEpisodeId: null,
    selectedCharacterId: null,
    deploymentVersion: null,
  };

  const elements = {
    showSelect: document.getElementById('show-select'),
    showTitle: document.getElementById('show-title'),
    showMeta: document.getElementById('show-meta'),
    showDescription: document.getElementById('show-description'),
    seasonSelect: document.getElementById('season-select'),
    episodeSelect: document.getElementById('episode-select'),
    episodeDetails: document.getElementById('episode-details'),
    characterSelect: document.getElementById('character-select'),
    characterDetails: document.getElementById('character-details'),
    connectionStatus: document.getElementById('connection-status'),
    toast: document.getElementById('toast'),
    authModal: document.getElementById('auth-modal'),
    authForm: document.getElementById('auth-form'),
    authTokenInput: document.getElementById('auth-token'),
    authFeedback: document.getElementById('auth-feedback'),
    authCancel: document.getElementById('auth-cancel'),
    changeTokenBtn: document.getElementById('change-token-btn'),
    appVersion: document.getElementById('app-version'),
    authVersion: document.getElementById('auth-version'),
  };

  let toastTimer = null;
  let showRequestToken = 0;
  let seasonRequestToken = 0;
  let episodeRequestToken = 0;

  function setAuthFeedback(message, tone = 'info') {
    const feedback = elements.authFeedback;
    if (!feedback) return;
    feedback.textContent = message;
    feedback.hidden = !message;
    feedback.classList.remove('auth-feedback--error', 'auth-feedback--success');
    if (!message) {
      return;
    }
    if (tone === 'error') {
      feedback.classList.add('auth-feedback--error');
    } else if (tone === 'success') {
      feedback.classList.add('auth-feedback--success');
    }
  }

  function updateConnectionStatus(status) {
    const pill = elements.connectionStatus;
    pill.classList.remove('status-pill--connected', 'status-pill--error', 'status-pill--disconnected');
    switch (status) {
      case 'connected':
        pill.textContent = 'Connected';
        pill.classList.add('status-pill--connected');
        break;
      case 'error':
        pill.textContent = 'Error';
        pill.classList.add('status-pill--error');
        break;
      default:
        pill.textContent = 'Disconnected';
        pill.classList.add('status-pill--disconnected');
    }
  }

  function showToast(message) {
    const toast = elements.toast;
    toast.textContent = message;
    toast.classList.add('toast--visible');
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      toast.classList.remove('toast--visible');
    }, 3000);
  }

  function setVersionText(text) {
    const appVersion = elements.appVersion;
    const authVersion = elements.authVersion;
    if (appVersion) {
      if (text) {
        appVersion.textContent = text;
        appVersion.hidden = false;
      } else {
        appVersion.hidden = true;
      }
    }
    if (authVersion) {
      if (text) {
        authVersion.textContent = text;
        authVersion.hidden = false;
      } else {
        authVersion.hidden = true;
      }
    }
  }

  function openAuthModal() {
    elements.authModal.hidden = false;
    requestAnimationFrame(() => {
      elements.authTokenInput.focus();
    });
  }

  function closeAuthModal() {
    elements.authModal.hidden = true;
    elements.authForm.reset();
    setAuthFeedback('');
  }

  function persistToken(token) {
    state.token = token;
    try {
      if (token) {
        localStorage.setItem('tvdb_api_token', token);
      } else {
        localStorage.removeItem('tvdb_api_token');
      }
    } catch (error) {
      console.warn('Failed to persist API token to localStorage', error);
      if (token) {
        showToast('Connected, but unable to remember the API token in this browser.');
      }
    }
  }

  function handleUnauthorized() {
    persistToken('');
    updateConnectionStatus('disconnected');
    setAuthFeedback('Invalid API token. Please try again.', 'error');
    openAuthModal();
    showToast('Authentication required. Enter a valid API token.');
    throw new Error('Unauthorized');
  }

  async function apiFetch(path, options = {}) {
    const headers = new Headers(options.headers || {});
    if (state.token) {
      headers.set('Authorization', `Bearer ${state.token}`);
    }
    const response = await fetch(path, { ...options, headers });
    if (response.status === 401) {
      handleUnauthorized();
    }
    if (!response.ok) {
      let message = `Request failed (${response.status})`;
      try {
        const data = await response.json();
        if (data && data.error) message = data.error;
      } catch (err) {
        // ignore JSON parse errors
      }
      throw new Error(message);
    }
    if (response.status === 204) return null;
    return response.json();
  }

  function renderShowDetails(show) {
    if (!show) {
      elements.showTitle.textContent = 'Select a show to see details';
      elements.showMeta.textContent = '';
      elements.showDescription.textContent = '';
      return;
    }
    elements.showTitle.textContent = show.title;
    const metaParts = [];
    if (show.year) metaParts.push(show.year);
    if (show.created_at) {
      const created = new Date(show.created_at);
      if (!Number.isNaN(created.getTime())) {
        metaParts.push(`Added ${created.toLocaleDateString()}`);
      }
    }
    elements.showMeta.textContent = metaParts.join(' • ');
    elements.showDescription.textContent = show.description || 'No description available yet for this show.';
  }

  function renderSeasons() {
    const select = elements.seasonSelect;
    if (!select) return;
    select.innerHTML = '';
    if (!state.selectedShowId) {
      select.innerHTML = '<option value="">Select a show to load seasons</option>';
      select.disabled = true;
      return;
    }
    if (!state.seasons.length) {
      select.innerHTML = '<option value="">No seasons found for this show.</option>';
      select.disabled = true;
      return;
    }
    select.disabled = false;
    const options = state.seasons
      .map((season) => `<option value="${season.season_number}">Season ${season.season_number}</option>`);
    select.innerHTML = ['<option value="">Select a season...</option>'].concat(options).join('');
    if (state.selectedSeasonNumber != null) {
      select.value = String(state.selectedSeasonNumber);
    } else {
      select.value = '';
    }
  }

  function renderEpisodes() {
    const select = elements.episodeSelect;
    if (!select) return;
    select.innerHTML = '';
    if (!state.selectedSeasonNumber) {
      select.innerHTML = '<option value="">Select a season to load episodes</option>';
      select.disabled = true;
      return;
    }
    if (!state.episodes.length) {
      select.innerHTML = '<option value="">No episodes found for this season.</option>';
      select.disabled = true;
      return;
    }
    select.disabled = false;
    const options = state.episodes.map((episode, index) => {
      const title = episode.title || `Episode ${index + 1}`;
      return `<option value="${episode.id}">${title}</option>`;
    });
    select.innerHTML = ['<option value="">Select an episode...</option>'].concat(options).join('');
    if (state.selectedEpisodeId) {
      select.value = String(state.selectedEpisodeId);
    } else {
      select.value = '';
    }
  }

  function renderEpisodeDetails(episode) {
    const panel = elements.episodeDetails;
    panel.innerHTML = '';
    const heading = document.createElement('h3');
    heading.textContent = episode ? episode.title || 'Untitled episode' : 'Episode details';
    panel.appendChild(heading);
    if (!episode) {
      const placeholder = document.createElement('p');
      placeholder.className = 'muted';
      placeholder.textContent = 'Select an episode to see its synopsis.';
      panel.appendChild(placeholder);
      return;
    }
    const meta = document.createElement('p');
    meta.className = 'muted';
    const bits = [];
    if (episode.air_date) {
      const airDate = new Date(episode.air_date);
      if (!Number.isNaN(airDate.getTime())) bits.push(`Aired ${airDate.toLocaleDateString()}`);
    }
    if (state.selectedSeasonNumber != null) {
      bits.push(`Season ${state.selectedSeasonNumber}`);
    }
    panel.appendChild(meta);
    meta.textContent = bits.join(' • ');
    const description = document.createElement('p');
    description.textContent = episode.description || 'No description is available for this episode yet.';
    panel.appendChild(description);
  }

  function renderCharacters() {
    const select = elements.characterSelect;
    if (!select) return;
    select.innerHTML = '';
    if (!state.selectedEpisodeId) {
      select.innerHTML = '<option value="">Select an episode to view characters</option>';
      select.disabled = true;
      renderCharacterDetails(null);
      return;
    }
    if (!state.characters.length) {
      select.innerHTML = '<option value="">No characters linked to this episode yet.</option>';
      select.disabled = true;
      renderCharacterDetails(null);
      return;
    }
    select.disabled = false;
    const options = state.characters.map((character) => `<option value="${character.id}">${character.name}</option>`);
    select.innerHTML = ['<option value="">Select a character...</option>'].concat(options).join('');
    if (state.selectedCharacterId != null) {
      select.value = String(state.selectedCharacterId);
    } else {
      select.value = '';
    }
    const selected = state.characters.find((character) => character.id === state.selectedCharacterId) || null;
    renderCharacterDetails(selected);
  }

  function renderCharacterDetails(character) {
    const panel = elements.characterDetails;
    if (!panel) return;
    panel.innerHTML = '';
    const heading = document.createElement('h3');
    heading.textContent = character ? character.name : 'Character details';
    panel.appendChild(heading);
    if (!state.selectedEpisodeId) {
      const placeholder = document.createElement('p');
      placeholder.className = 'muted';
      placeholder.textContent = 'Select an episode to view characters.';
      panel.appendChild(placeholder);
      return;
    }
    if (!state.characters.length) {
      const placeholder = document.createElement('p');
      placeholder.className = 'muted';
      placeholder.textContent = 'No characters linked to this episode yet.';
      panel.appendChild(placeholder);
      return;
    }
    if (!character) {
      const placeholder = document.createElement('p');
      placeholder.className = 'muted';
      placeholder.textContent = 'Select a character to see more details.';
      panel.appendChild(placeholder);
      return;
    }
    const actorName = character.actor_name || (character.actor && character.actor.name);
    const actor = document.createElement('p');
    actor.className = 'muted';
    actor.textContent = actorName ? `Portrayed by ${actorName}` : 'No actor information available yet.';
    panel.appendChild(actor);
  }

  async function loadDeploymentVersion() {
    const fallbackText = 'Version unavailable';
    try {
      const response = await fetch('/deployment-version');
      if (!response.ok) {
        throw new Error(`Request failed (${response.status})`);
      }
      const data = await response.json();
      state.deploymentVersion = data;
      const parts = [];
      const versionLabel = data.appVersion || data.packageVersion || '';
      if (versionLabel) {
        parts.push(`Version ${versionLabel}`);
      }
      if (data.buildNumber !== undefined && data.buildNumber !== null) {
        const buildText = String(data.buildNumber).trim();
        if (buildText) {
          parts.push(`Build ${buildText}`);
        }
      }
      const displayText = parts.join(' • ') || fallbackText;
      setVersionText(displayText);
    } catch (error) {
      console.warn('Failed to load deployment version', error);
      setVersionText(fallbackText);
    }
  }

  async function loadShows() {
    try {
      const shows = await apiFetch('/shows');
      updateConnectionStatus('connected');
      state.shows = Array.isArray(shows) ? shows : [];
      if (!state.shows.length) {
        elements.showSelect.innerHTML = '<option value="">No shows found</option>';
        renderShowDetails(null);
        renderSeasons();
        renderEpisodes();
        renderCharacters();
        return true;
      }
      elements.showSelect.innerHTML = ['<option value="">Select a show...</option>']
        .concat(state.shows.map((show) => `<option value="${show.id}">${show.title}</option>`))
        .join('');
      const storedShowId = state.selectedShowId || Number(elements.showSelect.value);
      const defaultShowId = storedShowId || state.shows[0].id;
      elements.showSelect.value = String(defaultShowId);
      await selectShow(defaultShowId);
      return true;
    } catch (error) {
      console.error(error);
      if (error.message !== 'Unauthorized') {
        updateConnectionStatus('error');
        showToast(error.message);
      }
      return false;
    }
  }

  async function selectShow(showId) {
    if (!showId) {
      showRequestToken += 1;
      seasonRequestToken += 1;
      episodeRequestToken += 1;
      state.selectedShowId = null;
      state.seasons = [];
      state.characters = [];
      state.episodes = [];
      state.selectedSeasonNumber = null;
      state.selectedEpisodeId = null;
      state.selectedCharacterId = null;
      renderShowDetails(null);
      renderSeasons();
      renderEpisodes();
      renderEpisodeDetails(null);
      renderCharacters();
      return;
    }
    state.selectedShowId = Number(showId);
    const show = state.shows.find((item) => item.id === state.selectedShowId);
    renderShowDetails(show);
    const requestId = ++showRequestToken;
    seasonRequestToken += 1;
    episodeRequestToken += 1;
    try {
      const seasons = await apiFetch(`/shows/${state.selectedShowId}/seasons`);
      updateConnectionStatus('connected');
      if (requestId !== showRequestToken) return;
      state.seasons = Array.isArray(seasons) ? seasons : [];
      state.selectedSeasonNumber = null;
      renderSeasons();
      state.episodes = [];
      state.selectedEpisodeId = null;
      state.characters = [];
      state.selectedCharacterId = null;
      renderCharacters();
      renderEpisodes();
      renderEpisodeDetails(null);
      const firstSeason = state.seasons[0];
      if (firstSeason) {
        await selectSeason(firstSeason.season_number);
      } else {
        state.episodes = [];
        state.selectedEpisodeId = null;
        state.selectedCharacterId = null;
        renderEpisodes();
        renderEpisodeDetails(null);
      }
    } catch (error) {
      console.error(error);
      if (error.message !== 'Unauthorized') {
        updateConnectionStatus('error');
        showToast(error.message);
      }
    }
  }

  async function selectSeason(seasonNumber) {
    if (seasonNumber == null) {
      seasonRequestToken += 1;
      episodeRequestToken += 1;
      state.selectedSeasonNumber = null;
      state.selectedEpisodeId = null;
      state.selectedCharacterId = null;
      state.episodes = [];
      state.characters = [];
      renderSeasons();
      renderEpisodes();
      renderEpisodeDetails(null);
      renderCharacters();
      return;
    }
    const requestId = ++seasonRequestToken;
    episodeRequestToken += 1;
    state.selectedSeasonNumber = Number(seasonNumber);
    state.selectedEpisodeId = null;
    state.selectedCharacterId = null;
    state.characters = [];
    state.episodes = [];
    renderSeasons();
    renderEpisodes();
    renderEpisodeDetails(null);
    renderCharacters();
    try {
      const episodes = await apiFetch(`/shows/${state.selectedShowId}/seasons/${state.selectedSeasonNumber}/episodes`);
      updateConnectionStatus('connected');
      if (requestId !== seasonRequestToken) return;
      state.episodes = Array.isArray(episodes) ? episodes : [];
      if (!state.episodes.length) {
        renderEpisodes();
        return;
      }
      renderEpisodes();
      await selectEpisode(state.episodes[0].id);
    } catch (error) {
      console.error(error);
      if (error.message !== 'Unauthorized') {
        updateConnectionStatus('error');
        showToast(error.message);
      }
    }
  }

  async function selectEpisode(episodeId) {
    if (episodeId == null || episodeId === '') {
      episodeRequestToken += 1;
      state.selectedEpisodeId = null;
      state.characters = [];
      state.selectedCharacterId = null;
      renderEpisodes();
      renderEpisodeDetails(null);
      renderCharacters();
      return;
    }
    state.selectedEpisodeId = Number(episodeId);
    state.characters = [];
    state.selectedCharacterId = null;
    renderEpisodes();
    const episode = state.episodes.find((ep) => ep.id === state.selectedEpisodeId) || null;
    renderEpisodeDetails(episode);
    renderCharacters();
    if (!state.selectedEpisodeId || !episode) {
      return;
    }
    const requestId = ++episodeRequestToken;
    try {
      const characters = await apiFetch(`/episodes/${state.selectedEpisodeId}/characters`);
      updateConnectionStatus('connected');
      if (requestId !== episodeRequestToken) return;
      state.characters = Array.isArray(characters) ? characters : [];
      state.selectedCharacterId = state.characters.length ? state.characters[0].id : null;
      renderCharacters();
    } catch (error) {
      console.error(error);
      if (error.message !== 'Unauthorized') {
        updateConnectionStatus('error');
        showToast(error.message);
      }
    }
  }

  function selectCharacter(characterId) {
    if (characterId == null || characterId === '') {
      state.selectedCharacterId = null;
      renderCharacters();
      return;
    }
    state.selectedCharacterId = Number(characterId);
    renderCharacters();
  }

  function attachEventListeners() {
    elements.showSelect.addEventListener('change', (event) => {
      selectShow(Number(event.target.value));
    });

    elements.seasonSelect.addEventListener('change', (event) => {
      const value = event.target.value;
      selectSeason(value ? Number(value) : null);
    });

    elements.episodeSelect.addEventListener('change', (event) => {
      const value = event.target.value;
      selectEpisode(value ? Number(value) : '');
    });

    elements.characterSelect.addEventListener('change', (event) => {
      const value = event.target.value;
      selectCharacter(value ? Number(value) : '');
    });

    elements.authForm.addEventListener('submit', async (event) => {
      event.preventDefault();
      const token = elements.authTokenInput.value.trim();
      if (!token) return;
      setAuthFeedback('Checking token...');
      persistToken(token);
      const ok = await loadShows();
      if (ok) {
        closeAuthModal();
        showToast('Connected to the API.');
      } else if (!elements.authFeedback.textContent) {
        setAuthFeedback('Unable to connect. Check the token and try again.', 'error');
      }
    });

    elements.authCancel.addEventListener('click', () => {
      closeAuthModal();
      if (!state.token) {
        updateConnectionStatus('disconnected');
      }
    });

    elements.changeTokenBtn.addEventListener('click', () => {
      elements.authTokenInput.value = state.token;
      setAuthFeedback('');
      openAuthModal();
    });
  }

  async function bootstrap() {
    loadDeploymentVersion();
    attachEventListeners();
    let storedToken = null;
    try {
      storedToken = localStorage.getItem('tvdb_api_token');
    } catch (error) {
      console.warn('Failed to read API token from localStorage', error);
    }
    if (storedToken) {
      persistToken(storedToken);
      const ok = await loadShows();
      if (ok) {
        return;
      }
    }
    updateConnectionStatus('disconnected');
    setAuthFeedback('');
    openAuthModal();
  }

  bootstrap();
})();
