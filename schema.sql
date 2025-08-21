-- Actors
CREATE TABLE IF NOT EXISTS actors (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(255) NOT NULL UNIQUE,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- Shows
CREATE TABLE IF NOT EXISTS shows (
  id INT AUTO_INCREMENT PRIMARY KEY,
  title VARCHAR(255) NOT NULL,
  description TEXT,
  year INT,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_shows_title_year (title, year)
) ENGINE=InnoDB;

-- Seasons (belongs to Show)
CREATE TABLE IF NOT EXISTS seasons (
  id INT AUTO_INCREMENT PRIMARY KEY,
  show_id INT NOT NULL,
  season_number INT NOT NULL,
  year INT,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_season_per_show (show_id, season_number),
  KEY idx_seasons_show (show_id),
  CONSTRAINT fk_seasons_show FOREIGN KEY (show_id) REFERENCES shows(id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- Episodes (belongs to Season)
CREATE TABLE IF NOT EXISTS episodes (
  id INT AUTO_INCREMENT PRIMARY KEY,
  season_id INT NOT NULL,
  air_date DATE,
  title VARCHAR(255) NOT NULL,
  description TEXT,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_episode_per_season (season_id, title),
  KEY idx_episodes_season (season_id),
  CONSTRAINT fk_episodes_season FOREIGN KEY (season_id) REFERENCES seasons(id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- Characters (belongs to Show, refers to Actor; actor is optional so we can set NULL)
CREATE TABLE IF NOT EXISTS characters (
  id INT AUTO_INCREMENT PRIMARY KEY,
  show_id INT NOT NULL,
  name VARCHAR(255) NOT NULL,
  actor_id INT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_character_per_show (show_id, name),
  KEY idx_characters_show (show_id),
  KEY idx_characters_actor (actor_id),
  CONSTRAINT fk_characters_show FOREIGN KEY (show_id) REFERENCES shows(id) ON DELETE CASCADE,
  CONSTRAINT fk_characters_actor FOREIGN KEY (actor_id) REFERENCES actors(id) ON DELETE SET NULL
) ENGINE=InnoDB;

-- Episodes ↔ Characters (many-to-many)
CREATE TABLE IF NOT EXISTS episode_characters (
  id INT AUTO_INCREMENT PRIMARY KEY,
  episode_id INT NOT NULL,
  character_id INT NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_episode_character (episode_id, character_id),
  KEY idx_epchar_episode (episode_id),
  KEY idx_epchar_character (character_id),
  CONSTRAINT fk_epchar_episode FOREIGN KEY (episode_id) REFERENCES episodes(id) ON DELETE CASCADE,
  CONSTRAINT fk_epchar_character FOREIGN KEY (character_id) REFERENCES characters(id) ON DELETE CASCADE
) ENGINE=InnoDB;
