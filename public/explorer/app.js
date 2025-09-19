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
  };

  const elements = {
    showSelect: document.getElementById('show-select'),
    showTitle: document.getElementById('show-title'),
    showMeta: document.getElementById('show-meta'),
    showDescription: document.getElementById('show-description'),
    seasonList: document.getElementById('season-list'),
    episodesList: document.getElementById('episodes-list'),
    episodeDetails: document.getElementById('episode-details'),
    charactersGrid: document.getElementById('characters-grid'),
    connectionStatus: document.getElementById('connection-status'),
    toast: document.getElementById('toast'),
    authModal: document.getElementById('auth-modal'),
    authForm: document.getElementById('auth-form'),
    authTokenInput: document.getElementById('auth-token'),
    authCancel: document.getElementById('auth-cancel'),
    changeTokenBtn: document.getElementById('change-token-btn'),
  };

  let toastTimer = null;
  let showRequestToken = 0;

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

  function openAuthModal() {
    elements.authModal.hidden = false;
    requestAnimationFrame(() => {
      elements.authTokenInput.focus();
    });
  }

  function closeAuthModal() {
    elements.authModal.hidden = true;
    elements.authForm.reset();
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
    const container = elements.seasonList;
    container.innerHTML = '';
    if (!state.seasons.length) {
      container.innerHTML = '<div class="empty-state">No seasons found for this show.</div>';
      return;
    }
    for (const season of state.seasons) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'season-chip' + (season.season_number === state.selectedSeasonNumber ? ' season-chip--active' : '');
      button.textContent = `Season ${season.season_number}`;
      button.dataset.seasonNumber = String(season.season_number);
      container.appendChild(button);
    }
  }

  function renderEpisodes() {
    const list = elements.episodesList;
    list.innerHTML = '';
    if (!state.selectedSeasonNumber) {
      list.innerHTML = '<div class="empty-state">Select a season to load episodes.</div>';
      return;
    }
    if (!state.episodes.length) {
      list.innerHTML = '<div class="empty-state">No episodes found for this season.</div>';
      return;
    }
    state.episodes.forEach((episode, index) => {
      const card = document.createElement('button');
      card.type = 'button';
      card.className = 'episode-card' + (episode.id === state.selectedEpisodeId ? ' episode-card--active' : '');
      card.dataset.episodeId = String(episode.id);
      const title = document.createElement('h4');
      title.textContent = episode.title || `Episode ${index + 1}`;
      const info = document.createElement('p');
      const parts = [];
      if (episode.air_date) {
        const airDate = new Date(episode.air_date);
        if (!Number.isNaN(airDate.getTime())) parts.push(airDate.toLocaleDateString());
      }
      parts.push(`Episode ${index + 1}`);
      info.textContent = parts.join(' • ');
      card.appendChild(title);
      card.appendChild(info);
      list.appendChild(card);
    });
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
    const grid = elements.charactersGrid;
    grid.innerHTML = '';
    if (!state.selectedShowId) {
      grid.innerHTML = '<div class="empty-state">Select a show to view characters.</div>';
      return;
    }
    if (!state.characters.length) {
      grid.innerHTML = '<div class="empty-state">No characters available for this show.</div>';
      return;
    }
    for (const character of state.characters) {
      const card = document.createElement('article');
      card.className = 'character-card';
      const name = document.createElement('h4');
      name.textContent = character.name;
      const actor = document.createElement('span');
      actor.textContent = character.actor_name ? `Portrayed by ${character.actor_name}` : 'No actor listed';
      card.appendChild(name);
      card.appendChild(actor);
      grid.appendChild(card);
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
      state.selectedShowId = null;
      state.seasons = [];
      state.characters = [];
      state.episodes = [];
      state.selectedSeasonNumber = null;
      state.selectedEpisodeId = null;
      renderShowDetails(null);
      renderSeasons();
      renderEpisodes();
      renderCharacters();
      return;
    }
    state.selectedShowId = Number(showId);
    const show = state.shows.find((item) => item.id === state.selectedShowId);
    renderShowDetails(show);
    const requestId = ++showRequestToken;
    try {
      const [seasons, characters] = await Promise.all([
        apiFetch(`/shows/${state.selectedShowId}/seasons`),
        apiFetch(`/shows/${state.selectedShowId}/characters`),
      ]);
      updateConnectionStatus('connected');
      if (requestId !== showRequestToken) return;
      state.seasons = Array.isArray(seasons) ? seasons : [];
      state.characters = Array.isArray(characters) ? characters : [];
      state.selectedSeasonNumber = state.seasons[0]?.season_number || null;
      renderSeasons();
      renderCharacters();
      if (state.selectedSeasonNumber != null) {
        await selectSeason(state.selectedSeasonNumber);
      } else {
        state.episodes = [];
        state.selectedEpisodeId = null;
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
    if (seasonNumber == null) return;
    state.selectedSeasonNumber = Number(seasonNumber);
    renderSeasons();
    try {
      const episodes = await apiFetch(`/shows/${state.selectedShowId}/seasons/${state.selectedSeasonNumber}/episodes`);
      updateConnectionStatus('connected');
      state.episodes = Array.isArray(episodes) ? episodes : [];
      state.selectedEpisodeId = state.episodes[0]?.id || null;
      renderEpisodes();
      const selectedEpisode = state.episodes.find((ep) => ep.id === state.selectedEpisodeId) || null;
      renderEpisodeDetails(selectedEpisode);
    } catch (error) {
      console.error(error);
      if (error.message !== 'Unauthorized') {
        updateConnectionStatus('error');
        showToast(error.message);
      }
    }
  }

  function selectEpisode(episodeId) {
    state.selectedEpisodeId = Number(episodeId);
    renderEpisodes();
    const episode = state.episodes.find((ep) => ep.id === state.selectedEpisodeId) || null;
    renderEpisodeDetails(episode);
  }

  function attachEventListeners() {
    elements.showSelect.addEventListener('change', (event) => {
      selectShow(Number(event.target.value));
    });

    elements.seasonList.addEventListener('click', (event) => {
      const target = event.target;
      if (target instanceof HTMLElement && target.dataset.seasonNumber) {
        selectSeason(Number(target.dataset.seasonNumber));
      }
    });

    elements.episodesList.addEventListener('click', (event) => {
      const target = event.target instanceof HTMLElement ? event.target.closest('.episode-card') : null;
      if (target && target.dataset.episodeId) {
        selectEpisode(Number(target.dataset.episodeId));
      }
    });

    elements.authForm.addEventListener('submit', async (event) => {
      event.preventDefault();
      const token = elements.authTokenInput.value.trim();
      if (!token) return;
      persistToken(token);
      closeAuthModal();
      const ok = await loadShows();
      if (ok) {
        showToast('Connected to the API.');
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
      openAuthModal();
    });
  }

  async function bootstrap() {
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
    openAuthModal();
  }

  bootstrap();
})();
